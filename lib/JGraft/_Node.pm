package JGraft::_Node;
# VERSION
# ABSTRACT: Shared constructor and notation handling for JGraft nodes
use strict;
use warnings;
use Carp 'croak';
use Scalar::Util qw(blessed refaddr);
use JGraft::Util ();
use JSON::PP ();

# Keep the constructor's private names while sharing predicates with execution.
*_type= \&JGraft::Util::type_mask;
*_finite= \&JGraft::Util::is_finite;
*_integer= \&JGraft::Util::is_integer;
*_is_expr= \&JGraft::Util::is_expr;
*_is_action= \&JGraft::Util::is_action;

sub _name { (my $name= ref($_[0]) || $_[0]) =~ s/.*:://; $name }
sub _bad { croak 'INVALID_GRAFT: '.join('', @_) }

sub _new {
   my $class= shift;
   $class= ref($class) || $class;
   if (@_ == 1 && ref $_[0] eq 'ARRAY') {
      return $class->_construct($_[0], 0, {});
   }
   @_ % 2 == 0 or _bad('Expected an operand arrayref or name/value attributes');
   my %attrs;
   while (@_) {
      my ($key, $value)= splice @_, 0, 2;
      defined $key && !ref $key or _bad('Invalid attribute name');
      exists $attrs{$key} and _bad("Duplicate attribute '$key'");
      $attrs{$key}= $value;
   }
   my $forms= $class->forms;
   for my $form (@$forms) {
      my $args= _assemble($form, \%attrs);
      next unless defined $args && _fits($form, scalar @$args);
      return $class->_construct($args, 0, {}, $form);
   }
   _bad($class, ': attributes do not describe a supported argument form');
}

# _parse deliberately receives the operation token as well as its operands.
sub _parse {
   my ($class, $in, $seen)= @_;
   ref $in eq 'ARRAY' && @$in or _bad('Expected a complete operation array');
   my ($token, @args)= @$in;
   $class->get_class($token) eq $class or _bad("Operation does not name $class");
   $seen ||= {};
   my $addr= refaddr($in);
   $seen->{$addr} and _bad('Cyclic notation');
   local $seen->{$addr}= 1;
   return $class->_construct([@$in[1..$#$in]], 1, $seen);
}

sub _fits {
   my ($form, $count)= @_;
   return 0 if $count < $form->{min};
   my $fixed= scalar @{$form->{fields} || []};
   return $count <= $fixed unless $form->{repeat};
   return 0 if $count < $fixed;
   my $width= @{$form->{repeat}} - 1;
   my $remaining= $count - $fixed;
   if ($form->{tail}) {
      return $remaining >= 1 && ($remaining - 1) % $width == 0
         unless $form->{optional_tail};
      return $remaining % $width == 0 || ($remaining >= 1 && ($remaining - 1) % $width == 0);
   }
   return $remaining % $width == 0;
}

sub _assemble {
   my ($form, $attrs)= @_;
   my %remaining= %$attrs;
   my @args;
   my $fields= $form->{fields} || [];
   my $last= -1;
   for my $i (0..$#$fields) { $last= $i if exists $remaining{$fields->[$i][0]} }
   $last= $#$fields if $form->{repeat};
   for my $i (0..$last) {
      my $field= $fields->[$i];
      if (exists $remaining{$field->[0]}) { push @args, delete $remaining{$field->[0]} }
      elsif (@$field > 2) { push @args, $field->[2] }
      else { return }
   }
   if (my $repeat= $form->{repeat}) {
      my $list= exists $remaining{$repeat->[0]}? delete $remaining{$repeat->[0]} : [];
      return unless ref $list eq 'ARRAY';
      if (@$repeat == 2) { push @args, @$list }
      else {
         for my $pair (@$list) {
            return unless ref $pair eq 'ARRAY' && @$pair == @$repeat - 1;
            push @args, @$pair;
         }
      }
   }
   if (my $tail= $form->{tail}) {
      if (exists $remaining{$tail->[0]}) { push @args, delete $remaining{$tail->[0]} }
      elsif (!$form->{optional_tail}) { return }
   }
   return if keys %remaining;
   return \@args;
}

sub _construct {
   my ($class, $args, $parse, $seen, $form)= @_;
   unless ($form) {
      ($form)= grep _fits($_, scalar @$args), @{$class->forms};
   }
   $form or _bad($class, ': unsupported number of operands (', scalar(@$args), ')');
   my %attrs;
   my $i= 0;
   for my $field (@{$form->{fields} || []}) {
      last if $i == @$args;
      $attrs{$field->[0]}= _argument($args->[$i++], $field->[1], $parse, $seen);
   }
   if (my $repeat= $form->{repeat}) {
      my $end= @$args;
      my $width= @$repeat - 1;
      if ($form->{tail} && (!$form->{optional_tail} || ($end - $i) % $width)) {
         --$end;
         my $tail= $form->{tail};
         $attrs{$tail->[0]}= _argument($args->[$end], $tail->[1], $parse, $seen);
      }
      my @list;
      while ($i < $end) {
         my @group;
         for my $j (1..$#$repeat) {
            push @group, _argument($args->[$i++], $repeat->[$j], $parse, $seen);
         }
         push @list, $width == 1? $group[0] : \@group;
      }
      $attrs{$repeat->[0]}= \@list;
   }
   my $self= bless { %attrs, _form => $form }, $class;
   $self->_validate;
   return $self;
}

sub _argument {
   my ($value, $context, $parse, $seen)= @_;
   if ($context eq 'action') {
      return $value if _is_action($value);
      $parse or _bad('Expected a pre-parsed action object');
      ref $value eq 'ARRAY' or _bad('Actions must be operation arrays');
      return JGraft::Action->get_class($value->[0])->_parse($value, $seen);
   }
   return _metadata($value, $parse, $seen) if $context eq 'metadata';
   return _split_spec($value, $parse, $seen) if $context eq 'split';
   if ($context =~ /^(?:path|node_path|write_path|move_src|move_dst)$/) {
      return undef if !defined $value && $context =~ /^move_/;
      $value= _tree($value, $parse, $seen);
      if (!_is_expr($value) && (!ref $value || JSON::PP::is_bool($value))) {
         $value= JGraft::Expr::NODE->new([$value]);
      }
      _is_expr($value) && $value->is_ref or _bad('Path must be a reference expression');
      my $name= $value->_name;
      $context eq 'node_path' && $name ne 'NODE' and _bad('This path must use NODE');
      if ($context =~ /^(?:write_path|move_src|move_dst)$/) {
         $name =~ /^(?:NODE|TEMP|STASH)$/ or _bad("Read-only path namespace $name");
         $name ne 'NODE' && !@{$value->{path}} and _bad('Cannot overwrite or move a namespace root');
      }
      _path_elements($value->{path}, $context eq 'move_dst');
      return $value;
   }
   if ($context =~ /^(?:level|prop|numeric_prop|options)$/) {
      $value= _tree($value, 0, $seen, 1);
   }
   else { $value= _tree($value, $parse, $seen) }
   if ($context eq 'int' || $context eq 'nonneg_int' || $context eq 'rep_max' || $context eq 'nullable_int') {
      return $value if !defined $value && $context eq 'nullable_int';
      _expect($value, 4, 'integer');
      unless (_is_expr($value)) {
         _integer($value) or _bad('Expected a finite integer');
         $context eq 'nonneg_int' && $value < 0 and _bad('Expected a non-negative integer');
         $context eq 'rep_max' && $value < -1 and _bad('REP maximum must be at least -1');
      }
   }
   elsif ($context eq 'bound') {
      _expect($value, 1|4, 'number or null');
      !defined $value || _is_expr($value) || _finite($value) or _bad('Range bounds must be finite');
   }
   elsif ($context eq 'name') {
      _expect($value, 4|8, 'string or integer name');
      _is_expr($value) || _type($value) == 8 || _integer($value) or _bad('Name must be a string or integer');
   }
   elsif ($context eq 'capture_name') {
      _expect($value, 1|4|8, 'capture name or null');
      !defined $value || _is_expr($value) || _type($value) == 8 || _integer($value)
         or _bad('Capture name must be a string or integer');
   }
   elsif ($context eq 'prop' || $context eq 'numeric_prop') {
      my $type= _type($value);
      ($type == 8 || ($type == 4 && ($context ne 'prop'? _finite($value) : _integer($value))))
         or _bad('Invalid literal property name');
   }
   elsif ($context eq 'level') {
      my $type= _type($value);
      (($type == 8 && $value =~ /\A(?:info|warn|fail)\z/) || ($type == 4 && _integer($value) && $value >= 0 && $value <= 2))
         or _bad('RAISE level must be info, warn, fail, 0, 1, or 2');
   }
   elsif ($context eq 'message' && !_is_expr($value)) {
      _type($value) == 8 or _bad('RAISE message must be a string');
      for my $char (split //, $value) {
         my $cp= ord $char;
         ($cp < 32 || ($cp >= 127 && $cp <= 159) || ($cp >= 0xd800 && $cp <= 0xdfff)
            || ($cp >= 0xfdd0 && $cp <= 0xfdef) || ($cp & 0xffff) >= 0xfffe)
            and _bad('RAISE message contains a forbidden character');
      }
   }
   elsif ($context eq 'options') {
      _type($value) == 4 && ($value == 1 || $value == 2) or _bad('PROPS options must be numeric 1 or 2');
   }
   elsif ($context eq 'regex') { _regex_value($value) }
   elsif ($context eq 'chars') { _chars_value($value) }
   return $value;
}

sub _expect {
   my ($value, $types, $description)= @_;
   # FAIL and other always-failing expressions return no type. Preserve them:
   # they may deliberately be guarded by a condition or used as match failure.
   my $possible= _type($value);
   !$possible || ($possible & $types) or _bad("Operand cannot return a $description");
}

sub _tree {
   my ($value, $parse, $seen, $plain)= @_;
   return $value if !ref $value || JSON::PP::is_bool($value);
   if (_is_expr($value)) {
      $plain and _bad('Expressions are not allowed in literal data');
      return $value;
   }
   my $type= ref $value;
   $type eq 'ARRAY' || $type eq 'HASH' or _bad('Expected JSON data or an expression, got ', $type);
   if ($type eq 'ARRAY' && $parse && !$plain) {
      if (@$value == 1 && ref $value->[0] eq 'ARRAY') {
         my $addr= refaddr($value);
         $seen->{$addr} and _bad('Cyclic data');
         local $seen->{$addr}= 1;
         return _literal_array($value->[0], $parse, $seen);
      }
      @$value or _bad('Literal arrays must be escaped in notation');
      my $token= $value->[0];
      return JGraft::Expr->get_class($token)->_parse($value, $seen);
   }
   return _literal_array($value, $parse, $seen, $plain) if $type eq 'ARRAY';
   my $addr= refaddr($value);
   $seen->{$addr} and _bad('Cyclic data');
   local $seen->{$addr}= 1;
   my %copy;
   $copy{$_}= _tree($value->{$_}, $parse, $seen, $plain) for keys %$value;
   return \%copy;
}

sub _literal_array {
   my ($value, $parse, $seen, $plain)= @_;
   my $addr= refaddr($value);
   $seen->{$addr} and _bad('Cyclic data');
   local $seen->{$addr}= 1;
   return [map _tree($_, $parse, $seen, $plain), @$value];
}

sub _path_elements {
   my ($path, $half)= @_;
   my @elements;
   for my $value (@$path) {
      push @elements, ref $value eq 'ARRAY'? @$value : $value;
   }
   for my $i (0..$#elements) {
      my $v= $elements[$i];
      if (_is_expr($v)) { _expect($v, 2|4|8|16, 'path selector'); next }
      my $type= _type($v);
      next if $type == 8 || ($type == 2 && !$v);
      if ($type == 4 && _finite($v)) {
         next if _integer($v) || ($half && $i == $#elements && $v * 2 == int($v * 2));
      }
      _bad('Invalid literal path selector');
   }
}

sub _regex_value {
   my $v= shift;
   return if _is_expr($v);
   my $type= _type($v);
   return if $type == 8 || ($type == 4 && _integer($v) && $v >= 0 && $v <= 0x10ffff);
   _bad('Regex operands must be strings, codepoints, or expressions');
}

sub _chars_value {
   my $v= shift;
   if (_is_expr($v)) {
      $v->isa('JGraft::Expr::EXPR') or _bad('CHARS only permits EXPR references');
      return;
   }
   my $type= _type($v);
   return if $type == 1 || $type == 2 || $type == 8;
   return if $type == 4 && _integer($v) && $v >= 0 && $v <= 0x10ffff;
   _bad('Invalid CHARS operand');
}

sub _metadata {
   my ($value, $parse, $seen)= @_;
   ref $value eq 'HASH' or _bad('JGRAFT metadata must be a literal object');
   my $addr= refaddr($value);
   $seen->{$addr} and _bad('Cyclic metadata');
   local $seen->{$addr}= 1;
   my %copy;
   for my $key (keys %$value) {
      if ($key eq 'const' || $key eq 'expr') {
         my $list= $value->{$key};
         ref $list eq 'ARRAY' && @$list % 2 == 0 or _bad("Metadata $key must contain name/value pairs");
         my @defs;
         for (my $i= 0; $i < @$list; $i += 2) {
            my $name= _argument($list->[$i], 'prop', 0, $seen);
            push @defs, $name, _tree($list->[$i+1], $parse, $seen);
         }
         $copy{$key}= \@defs;
      }
      else { $copy{$key}= _tree($value->{$key}, 0, $seen, 1) }
   }
   if (exists $copy{v}) {
      _integer($copy{v}) && $copy{v} >= 1 or _bad('Metadata v must be a positive integer');
   }
   for my $key ('writer', 'comment') {
      !exists $copy{$key} || _type($copy{$key}) == 8 or _bad("Metadata $key must be a string");
   }
   return \%copy;
}

sub _split_spec {
   my ($value, $parse, $seen)= @_;
   unless (ref $value eq 'HASH') {
      $value= _tree($value, $parse, $seen);
      return $value if _type($value) == 8 || (_is_expr($value) && ($value->is_match || $value->is_ref));
      _bad('Split specification must be a string, match/reference expression, or literal object');
   }
   my $addr= refaddr($value);
   $seen->{$addr} and _bad('Cyclic split specification');
   local $seen->{$addr}= 1;
   exists $value->{sep} or _bad('Split specification requires sep');
   exists $value->{trim} && (exists $value->{ltrim} || exists $value->{rtrim})
      and _bad('trim cannot be combined with ltrim or rtrim');
   my %copy;
   for my $key (keys %$value) {
      if ($key =~ /\A(?:sep|element|ltrim|rtrim|trim)\z/) {
         $copy{$key}= _tree($value->{$key}, $parse, $seen);
         _regex_value($copy{$key});
      }
      elsif ($key eq 'default') {
         $copy{$key}= _tree($value->{$key}, $parse, $seen);
      }
      elsif ($key eq 'discard') {
         _type($value->{$key}) == 2 or _bad('discard must be a literal boolean');
         $copy{$key}= $value->{$key};
      }
      elsif ($key eq 'keep') {
         _type($value->{$key}) == 8 && $value->{$key} =~ /\A[<>\@]\z/ or _bad('Invalid keep value');
         $copy{$key}= $value->{$key};
      }
      else { _bad("Unknown split property '$key'") }
   }
   return \%copy;
}

sub _validate {
   my $self= shift;
   my $name= $self->_name;
   if ($self->isa('JGraft::Expr::Ref')) {
      _path_elements($self->{path}, 1) if exists $self->{path};
      $name eq 'TEMP' && !@{$self->{path}} and _bad('TEMP requires a path');
   }
   if ($name eq 'NUM' && defined $self->{min} && defined $self->{max}
      && !_is_expr($self->{min}) && !_is_expr($self->{max})) {
      $self->{min} <= $self->{max} or _bad('NUM bounds are reversed');
   }
   if ($name eq 'REP' && exists $self->{min} && exists $self->{max}
      && !_is_expr($self->{min}) && !_is_expr($self->{max})) {
      $self->{max} <= 0 || $self->{max} >= $self->{min} or _bad('REP bounds are reversed');
   }
   if ($name eq 'CHARS') {
      my $values= $self->{entries};
      for (my $i= 0; $i + 1 < @$values; ++$i) {
         my ($a, $b)= map _codepoint($_), @$values[$i, $i+1];
         if (defined $a && defined $b) {
            $a <= $b or _bad('CHARS range is reversed');
            ++$i;
         }
      }
   }
   if ($name eq 'JOIN' || $name eq 'ATSPLIT') {
      my $split= $self->{split_spec};
      if (_is_expr($split) && $split->is_match) { _bad('Regex joining requires a default separator') }
      if (ref $split eq 'HASH' && _is_expr($split->{sep}) && $split->{sep}->is_match) {
         exists $split->{keep} || exists $split->{default} or _bad('Regex joining requires a default separator');
         _expect($split->{default}, 8, 'string separator') unless exists $split->{keep};
      }
   }
}

sub _codepoint {
   my $v= shift;
   return 0x10ffff unless defined $v;
   return if _is_expr($v);
   my $type= _type($v);
   return $v if $type == 4;
   return ord($v) if $type == 8 && length($v) == 1;
   return;
}

sub _result_types {
   my $self= shift;
   my $name= $self->_name;
   return $self->{return_value_expr}->_result_types
      if $name eq 'LOCAL' && _is_expr($self->{return_value_expr});
   return _type($self->{return_value_expr}) if $name eq 'LOCAL';
   return $self->returns;
}

sub _encode_tree {
   my $v= shift;
   return $v unless ref $v;
   return $v if JSON::PP::is_bool($v);
   return $v->to_json_data if _is_expr($v) || _is_action($v);
   return [[map _encode_tree($_), @$v]] if ref $v eq 'ARRAY';
   return { map +($_ => _encode_tree($v->{$_})), keys %$v } if ref $v eq 'HASH';
   _bad('Cannot serialize ', ref($v));
}

sub _encode_argument {
   my ($v, $context)= @_;
   if ($context eq 'metadata') {
      my %copy= %$v;
      for my $key ('const', 'expr') {
         next unless exists $v->{$key};
         my @defs;
         for (my $i= 0; $i < @{$v->{$key}}; $i += 2) {
            push @defs, $v->{$key}[$i], _encode_tree($v->{$key}[$i+1]);
         }
         $copy{$key}= \@defs;
      }
      return \%copy;
   }
   if ($context eq 'split' && ref $v eq 'HASH') {
      return { map +($_ => _encode_tree($v->{$_})), keys %$v };
   }
   return _encode_tree($v);
}

sub to_json_data {
   my $self= shift;
   my $form= $self->{_form};
   my @args;
   for my $field (@{$form->{fields} || []}) {
      last unless exists $self->{$field->[0]};
      push @args, _encode_argument($self->{$field->[0]}, $field->[1]);
   }
   if (my $repeat= $form->{repeat}) {
      for my $item (@{$self->{$repeat->[0]}}) {
         if (@$repeat == 2) { push @args, _encode_argument($item, $repeat->[1]) }
         else {
            push @args, map _encode_argument($item->[$_-1], $repeat->[$_]), 1..$#$repeat;
         }
      }
   }
   if (my $tail= $form->{tail}) {
      push @args, _encode_argument($self->{$tail->[0]}, $tail->[1]) if exists $self->{$tail->[0]};
   }
   return [$self->_name, @args];
}

sub TO_JSON { shift->to_json_data(@_) }

=head1 DESCRIPTION

Internal shared support for action and expression classes. The C<forms> and
C<returns> class attributes describe operand names, arity, argument contexts,
and possible result types.
The public contracts are documented in L<JGraft::Action> and L<JGraft::Expr>.

=constructor new

Construct a concrete node from an operand arrayref or name/value attributes.
Constructor arrays are literal; notation decoding is performed by C<_parse>.

=method to_json_data

Return the JSON-compatible operation array, escaping literal arrays and
serializing nested action and expression objects in the proper contexts.

=method TO_JSON

Dispatch to C<to_json_data> for JSON encoders with C<convert_blessed> enabled.

=cut

1;
