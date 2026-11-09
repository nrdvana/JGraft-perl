package JGraft::_Format;
# VERSION
# ABSTRACT: Lay out JGraft operations as readable JSON
use strict;
use warnings;
use Carp 'croak';
use Scalar::Util qw(blessed refaddr);
use JSON::PP ();
use JGraft::Util qw(type_mask TYPE_NUMBER);

# Encode treats some noncharacters differently across Perl versions. JSON
# escapes preserve them without passing those scalars through a UTF-8 layer.
my $terminal=join('',map sprintf('\\x{%X}\\x{%X}',($_<<16)+0xfffe,($_<<16)+0xffff),0..16);
my $escape_chars=qr/([\x{d800}-\x{dfff}\x{fdd0}-\x{fdef}$terminal])/;

sub format {
   my ($class,$node,@options)=@_;
   blessed($node) && $node->isa('JGraft::Op') or croak 'format requires an action or expression object';
   return $class->_format($node,1,@options);
}
sub format_json {
   my ($class,$value,@options)=@_;
   return $class->_format($value,0,@options);
}
sub _format {
   my ($class,$value,$operation,@options)=@_;
   @options%2==0 or croak 'Expected formatting options as name/value pairs';
   my %options=(indent=>2,wrap=>79,prefix=>'',ids=>0,close=>'newline',@options);
   my %allowed=map {$_=>1} qw(indent wrap prefix ids close);
   $allowed{$_} or croak "Unknown formatting option '$_'" for keys %options;
   for my $key (qw(indent wrap)) {
      defined($options{$key}) && !ref($options{$key}) && $options{$key} =~ /\A[0-9]+\z/
         or croak "$key must be a nonnegative integer";
   }
   defined($options{prefix}) && !ref($options{prefix}) && $options{prefix} =~ /\A[ \t]*\z/
      or croak 'prefix must contain only spaces or tabs';
   defined($options{close}) && ($options{close} eq 'newline' || $options{close} eq 'inline')
      or croak 'close must be newline or inline';
   my $self=bless {options=>\%options,json=>JSON::PP->new->canonical->allow_nonref,
      operations=>{},generic=>{},flat=>{}},$class;
   my $data=$operation? $self->_node($value) : $self->_scan($value,{});
   return $self->_compact($data) unless $options{indent};
   return $options{prefix}.$self->_render($data,length($options{prefix}),$options{wrap},0);
}

# Serialization supplies the shape/escaping; its callback supplies node identity.
# In particular, metadata definition arrays and escaped literals are not nodes.
sub _node {
   my ($self,$node,$arguments)=@_;
   my $data=ref($node)? $node->to_json_data(sub {$self->_node(@_)}) : [$node->name,@$arguments];
   $self->_tag($data,$node);
   return $data;
}
sub _tag {
   my ($self,$data,$node)=@_;
   # Registry lookups can add string flags to cached IDs on old interpreters.
#__p5.28__
   $data->[0]=$self->{options}{ids}? $node->id : $node->name;
#__p5.8__
#   $data->[0]=$self->{options}{ids}? 0+$node->id : $node->name;
#__end__
   my $form=ref($node)? $node->{_form} : $node->forms->[0];
   my @groups;
   my $i=1;
   for my $field (@{$form->{fields} || []}) {
      last if $i>@$data-1;
      if ($field->[1] eq 'metadata') {
         for my $key (qw(const expr)) {
            my $defs=$data->[$i]{$key};
            next unless ref($defs) eq 'ARRAY';
            my @pairs;
            for (my $j=0;$j<@$defs;$j+=2) { push @pairs,{values=>[@$defs[$j,$j+1]],pair=>1} }
            $self->{operations}{refaddr($defs)}={groups=>\@pairs};
         }
      }
      push @groups,{values=>[$data->[$i++]]};
   }
   my $tail=$form->{tail} && ref($node) && exists $node->{$form->{tail}[0]};
   my $end=$#$data-($tail?1:0);
   if (my $repeat=$form->{repeat}) {
      my $width=@$repeat-1;
      $width=2 if $node->name eq 'MKOBJ';
      while ($i<=$end) {
         my $last=$i+$width-1;
         $last=$end if $last>$end;
         push @groups,{values=>[@$data[$i..$last]],pair=>$width>1};
         $i=$last+1;
      }
   }
   push @groups,{values=>[$data->[-1]],tail=>1} if $tail;
   $self->{operations}{refaddr($data)}={name=>$data->[0],arity=>$#$data,groups=>\@groups};
   return $data;
}

# A JSON document keeps its original notation, including shorthand paths and
# exact numeric tokens. Parsing supplies annotations, not replacement values.
sub _scan {
   my ($self,$value,$active)=@_;
   return $self->_node($value) if blessed($value) && $value->isa('JGraft::Op');
   return $value unless ref($value) eq 'ARRAY' || ref($value) eq 'HASH';
   my $id=refaddr($value);
   $active->{$id} and croak 'Cannot format cyclic JSON data';
   local $active->{$id}=1;
   if (ref($value) eq 'ARRAY' && @$value) {
      my $head=$value->[0];
      my $token=blessed($head) && (type_mask($head)==TYPE_NUMBER || type_mask($head)==JGraft::Util::TYPE_STRING())? "$head" : $head;
      my $graft_id=type_mask($head)==TYPE_NUMBER && $head==-1;
      if (defined($token) && !ref($token) && ($token eq 'JGRAFT' || $graft_id)) {
         require JGraft::Action;
         my $node=eval { JGraft::Action->new_from_json_data($value) };
         if ($node) {
            my $copy=$self->_copy($value,{});
            $self->_notation($copy,$node,'value');
            return $copy;
         }
      }
   }
   my $tie=ref($value) eq 'HASH'?tied(%$value):undef;
   my $out=ref($value) eq 'ARRAY'? [map $self->_scan($_,$active),@$value]
      : $tie && $tie->isa('JGraft::JSON::Object')?$tie->_clone(sub { $self->_scan($_[0],$active) })
      : {map +($_=>$self->_scan($value->{$_},$active)),keys %$value};
   $self->{generic}{refaddr($out)}=1;
   return $out;
}
sub _copy {
   my ($self,$value,$active)=@_;
   return $value unless ref($value) eq 'ARRAY' || ref($value) eq 'HASH';
   my $id=refaddr($value);
   $active->{$id} and croak 'Cannot format cyclic JSON data';
   local $active->{$id}=1;
   return [map $self->_copy($_,$active),@$value] if ref($value) eq 'ARRAY';
   my $tie=tied %$value;
   return $tie->_clone(sub { $self->_copy($_[0],$active) })
      if $tie && $tie->isa('JGraft::JSON::Object');
   return {map +($_=>$self->_copy($value->{$_},$active)),keys %$value};
}
sub _notation {
   my ($self,$raw,$node,$context)=@_;
   if (blessed($node) && $node->isa('JGraft::Op')) {
      # Implicit path selectors are scalars, not operation arrays.
      return unless ref($raw) eq 'ARRAY';
      my $form=$node->{_form};
      my $i=1;
      for my $field (@{$form->{fields} || []}) {
         last unless exists $node->{$field->[0]};
         $self->_notation($raw->[$i++],$node->{$field->[0]},$field->[1]);
      }
      if (my $repeat=$form->{repeat}) {
         for my $item (@{$node->{$repeat->[0]}}) {
            if (@$repeat==2) { $self->_notation($raw->[$i++],$item,$repeat->[1]) }
            else {
               for my $j (1..$#$repeat) { $self->_notation($raw->[$i++],$item->[$j-1],$repeat->[$j]) }
            }
         }
      }
      if (my $tail=$form->{tail}) {
         $self->_notation($raw->[$i],$node->{$tail->[0]},$tail->[1]) if exists $node->{$tail->[0]};
      }
      $self->_tag($raw,$node);
   }
   elsif (ref($node) eq 'HASH' && ref($raw) eq 'HASH') {
      for my $key (keys %$node) {
         if ($context eq 'metadata' && ($key eq 'const' || $key eq 'expr')) {
            for (my $i=1;$i<@{$node->{$key}};$i+=2) {
               $self->_notation($raw->{$key}[$i],$node->{$key}[$i],'value');
            }
         }
         elsif ($context ne 'metadata') { $self->_notation($raw->{$key},$node->{$key},'value') }
      }
   }
   elsif (ref($node) eq 'ARRAY' && ref($raw) eq 'ARRAY') {
      # Literal arrays in notation have one extra wrapper.
      my $items=$raw->[0];
      for my $i (0..$#$node) { $self->_notation($items->[$i],$node->[$i],'value') }
   }
}

sub _scalar {
   no warnings 'utf8';
   my ($self,$value)=@_;
   my $text;
   if (blessed($value) && !JSON::PP::is_bool($value)
      && (type_mask($value)==TYPE_NUMBER || type_mask($value)==JGraft::Util::TYPE_STRING())) {
      require JGraft::JSON;
      $text=JGraft::JSON->new->encode($value);
   }
   else { $text=$self->{json}->encode($value) }
   $text !~ /[^\x{0}-\x{10ffff}]/ or croak 'Cannot format codepoints above U+10FFFF';
   $text =~ s/$escape_chars/_unicode_escape(ord($1))/eg;
   return $text;
}
sub _unicode_escape {
   my $cp=shift;
   return sprintf('\\u%04x',$cp) if $cp<=0xffff;
   $cp-=0x10000;
   return sprintf('\\u%04x\\u%04x',0xd800+($cp>>10),0xdc00+($cp & 0x3ff));
}
sub _shape {
   my ($self,$value)=@_;
   if (ref($value) eq 'HASH') {
      my $tie=tied %$value;
      if ($tie && $tie->isa('JGraft::JSON::Object')) {
         my @groups;
         for (my $i=$tie->{head};defined $i;$i=$tie->{seq}[$i+1]) {
            $JGraft::JSON::Object::EXEC->_tick(1) if $JGraft::JSON::Object::EXEC;
            push @groups,{values=>[@{$tie->{tokens}}[$i,$i+1]],pair=>1,separator=>': '};
         }
         return ('{','}',\@groups);
      }
      return ('{','}',[map +{values=>[$_,$value->{$_}],pair=>1,separator=>': '},sort keys %$value]);
   }
   my $info=$self->{operations}{refaddr($value)};
   return ('['.$self->_scalar($info->{name}),']',$info->{groups}) if $info && exists $info->{name};
   return ('[',']',$info? $info->{groups} : [map +{values=>[$_]},@$value]);
}
sub _inline {
   my ($self,$value)=@_;
   return $self->_scalar($value) unless ref($value) eq 'ARRAY' || ref($value) eq 'HASH';
   my $id=refaddr($value);
   return $self->{flat}{$id} if exists $self->{flat}{$id};
   my ($open,$close,$groups)=$self->_shape($value);
   return $self->{flat}{$id}=undef if $self->{generic}{$id} && $self->_stacked($groups);
   my @parts;
   for my $group (@$groups) {
      my @items;
      for my $item (@{$group->{values}}) {
         my $info=ref($item) eq 'ARRAY'? $self->{operations}{refaddr($item)} : undef;
         return $self->{flat}{$id}=undef if $info && ($info->{arity} || 0)>1;
         my $text=$self->_inline($item);
         return $self->{flat}{$id}=undef unless defined $text;
         push @items,$text;
      }
      push @parts,join($group->{separator} || ', ',@items);
   }
   return $self->{flat}{$id}=$open.(@parts && length($open)>1?', ':'').join(', ',@parts).$close;
}
sub _stacked {
   my ($self,$groups)=@_;
   for my $group (@$groups) {
      for my $item (@{$group->{values}}) {
         return 1 if ref($item) eq 'ARRAY' && @$item>1;
         return 1 if ref($item) eq 'HASH' && keys(%$item)>1;
         return 1 unless defined $self->_inline($item);
      }
   }
   return 0;
}
sub _pad {
   my ($self,$column)=@_;
   my $prefix=$self->{options}{prefix};
   return $prefix.(' 'x($column-length($prefix)));
}
sub _group {
   my ($self,$group,$column,$width)=@_;
   my ($out,$current)=('',$column);
   my $separator=$group->{separator} || ', ';
   for my $value (@{$group->{values}}) {
      my $flat=$self->_inline($value);
      if (length $out) {
         my $fits=defined($flat) && (!$width || $current+length($separator)+length($flat)<=$width-1);
         if (!$fits && (ref($value) eq 'ARRAY' || ref($value) eq 'HASH')) {
            my ($opening)=$self->_shape($value);
            $fits=!$width || $current+length($separator)+length($opening)<=$width-1;
         }
         if ($fits) {
            $out.=$separator; $current+=length($separator);
         }
         else {
            (my $punctuation=$separator) =~ s/ +\z//;
            $current=$column+$self->{options}{indent};
            $out.=$punctuation."\n".$self->_pad($current);
         }
      }
      my $text=$self->_render($value,$current,$width,1,$column);
      $out.=$text;
      $current=$text =~ /\n([^\n]*)\z/? length($1) : $current+length($text);
   }
   return $out;
}
sub _render {
   my ($self,$value,$column,$width,$reserve,$base)=@_;
   $base=$column unless defined $base;
   my $flat=$self->_inline($value);
   my $container=ref($value) eq 'ARRAY' || ref($value) eq 'HASH';
   return $flat if !$container || (defined($flat) && (!$width || $column+length($flat)<=$width-$reserve));
   my ($open,$close,$groups)=$self->_shape($value);
   return $open.$close unless @$groups;
   my $indent=$base+$self->{options}{indent};
   $width*=2 while $width && $width-$indent<40;
   my $argument_width=$width && $self->{options}{close} eq 'inline'? $width-$reserve : $width;
   my $generic=$self->{generic}{refaddr($value)};
   my $stacked=$generic && $self->_stacked($groups);
   my $out=$open;
   my $written=length($open)>1;
   my $current=$column+length($open);
   for my $group (@$groups) {
      my (@items,$force);
      $force=$stacked || (!$generic && $group->{pair}) || $group->{tail};
      for my $item (@{$group->{values}}) {
         my $text=$self->_inline($item);
         push @items,$text if defined $text;
         my $info=ref($item) eq 'ARRAY'? $self->{operations}{refaddr($item)} : undef;
         $force=1 if !defined($text) || ($info && ($info->{arity} || 0)>1);
      }
      my $text=@items==@{$group->{values}}? join($group->{separator} || ', ',@items) : undef;
      if (!$force && defined($text) && (!$argument_width || $current+($written?2:0)+length($text)<=$argument_width-1)) {
         $out.=', ' if $written;
         $out.=$text;
         $current+=($written?2:0)+length($text);
      }
      else {
         $out.=',' if $written;
         $text=$self->_group($group,$indent,$argument_width);
         $out.="\n".$self->_pad($indent).$text;
         $current=$text =~ /\n([^\n]*)\z/? length($1) : $indent+length($text);
      }
      $written=1;
   }
   return $out.($self->{options}{close} eq 'newline'? "\n".$self->_pad($base) : '').$close;
}

sub _compact {
   my ($self,$value)=@_;
   my $state={text=>'',column=>0,width=>$self->{options}{wrap}};
   $self->_compact_value($value,$state);
   return $state->{text};
}
sub _emit {
   my ($self,$state,$token)=@_;
   if ($state->{width} && $state->{column} && $state->{column}+length($token)>$state->{width}) {
      $state->{text}.="\n"; $state->{column}=0;
   }
   $state->{text}.=$token; $state->{column}+=length($token);
}
sub _compact_value {
   my ($self,$value,$state)=@_;
   if (ref($value) eq 'ARRAY' || ref($value) eq 'HASH') {
      my $object=ref($value) eq 'HASH';
      $self->_emit($state,$object?'{':'[');
      my $tie=$object?tied(%$value):undef;
      if ($tie && $tie->isa('JGraft::JSON::Object')) {
         my $written=0;
         for (my $i=$tie->{head};defined $i;$i=$tie->{seq}[$i+1]) {
            $JGraft::JSON::Object::EXEC->_tick(1) if $JGraft::JSON::Object::EXEC;
            $self->_emit($state,',') if $written++;
            $self->_emit($state,$self->_scalar($tie->{tokens}[$i]));
            $self->_emit($state,':');
            $self->_compact_value($tie->{tokens}[$i+1],$state);
         }
         $self->_emit($state,'}');
         return;
      }
      my @keys=$object? sort keys %$value : (0..$#$value);
      for my $i (0..$#keys) {
         $self->_emit($state,',') if $i;
         if ($object) { $self->_emit($state,$self->_scalar($keys[$i])); $self->_emit($state,':') }
         $self->_compact_value($object?$value->{$keys[$i]}:$value->[$keys[$i]],$state);
      }
      $self->_emit($state,$object?'}':']');
   }
   else { $self->_emit($state,$self->_scalar($value)) }
}

=head1 DESCRIPTION

Shared formatter loaded only when an action or expression is formatted. It uses
the existing notation serializer and operand schemas to preserve literal arrays,
identify operations, and keep argument pairs together.

=method format

Internal entry point used by C<< $node->format(%options) >>. See
L<JGraft::Action/format> and L<JGraft::Expr/format> for formatting options.

=method format_json

Internal entry point for L<JGraft/jgformat>. It scans decoded JSON for valid
JGRAFT arrays and leaves invalid candidates as ordinary JSON. Raw notation and
preserved numeric tokens are retained. With zero indentation, the renderer emits
JSON tokens without optional spaces, inserting newlines only for width wrapping.

=cut

1;
