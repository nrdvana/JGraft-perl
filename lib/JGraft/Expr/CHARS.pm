package JGraft::Expr::CHARS;
# VERSION
# ABSTRACT: Match to a set of characters

=head1 DESCRIPTION

This object represents the L<CHARS Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-chars>.

The expression tests a character against the set described by L</entries>. Strings and
codepoints describe characters or ranges, booleans switch between inclusion and exclusion, and
EXPR references can include other CHARS definitions.

=attribute id

The numeric operation ID, C<19>.

=attribute entries

An arrayref of character-set entries: strings, Unicode codepoints, undef range bounds,
inclusion/exclusion booleans, or EXPR reference objects.

=constructor new

  ->new(%attributes);
  ->new([ @entries ]);
  ->new(qr/[a-zA-Z_]/);
  ->new([qr/\p{Lu}/]);

Construct via attribute names or a JGraft operand arrayref using values already inflated /
decoded from JGraft JSON notation.

The operand arrayref omits the operation name. Arrays are literal data, and nested actions or
expressions must already be objects.

The native regexp form accepts exactly one bracketed character class or one
shorthand such as C<qr/\d/> or C<qr/\p{Lu}/>. Anchors, groups, alternation,
quantifiers, and additional operands are rejected. The class is parsed into a
snapshot of its Unicode-codepoint membership, limited to U+0000 through U+10FFFF.
Regexp modifiers are respected; membership under case folding is restricted to
single codepoints rather than multi-character folds. Locale-sensitive classes
are captured using the locale active during construction.

The parser is adapted from Mock::Data::Charset. Unicode::UCD inversion lists are
used where available. Older Perls and modifiers requiring native interpretation
use a bounded scan of individual Unicode characters. Unicode properties reflect
the constructing interpreter's tables; serialized classes retain that snapshot.

=attribute invlist

A read-only arrayref of sorted, alternating inclusive start and exclusive limit
boundaries. The list has even length; its largest possible limit is 0x110000.
An empty list matches nothing. Ordinary literal entries can also be inspected
through this accessor, but unresolved EXPR references require an execution scope.

Execution uses inversion-list union/subtraction for class construction and binary
search for membership. Literal classes are cached within each execution; classes
containing EXPR references retain scope-dependent resolution. Resource accounting
includes list construction and binary-search steps.

=constructor new_from_json_data

  ->new_from_json_data(\@jgraft_json_array);

Construct from an already-decoded JGraft JSON array. Its first element is the expression name
or numeric ID; subsequent operands are recursively inflated according to their argument
contexts, including unescaping literal arrays.

=method to_json_data

Return an arrayref encoding the expression in JGraft JSON notation, suitable for
new_from_json_data. Nested nodes are encoded and literal arrays are escaped.

Regexp-created classes emit numeric endpoint pairs for every run of four or more
members, followed by one string containing all runs of one through three members.
An empty final string is omitted. This notation contains no regexp references.
Ordinary CHARS notation retains its original entries, including unresolved EXPR
references and strings whose interpretation depends on execution policy.

=cut

use strict;
use warnings;
no warnings 'recursion';
BEGIN { require JGraft::Expr; }
use Scalar::Util qw(refaddr reftype);
#__p5.28__
#__p5.8__
#use B ();
#__end__
use JGraft::Util qw(:types type_mask is_expr is_integer);
use JSON::PP ();

sub _is_regexp {
   my $value=shift;
#__p5.28__
   return ref($value) && (reftype($value) || '') eq 'REGEXP';
#__p5.8__
#   return 0 unless ref $value;
#   my $type=reftype($value) || '';
#   return 1 if $type eq 'REGEXP';
#   return 0 unless $type eq 'SCALAR';
#   my $object=B::svref_2object($value);
#   return 0 unless $object->can('MAGIC');
#   for (my $magic=$object->MAGIC; ref($magic) eq 'B::MAGIC'; $magic=$magic->MORE) {
#      return 1 if $magic->TYPE eq 'r';
#   }
#   return 0;
#__end__
}
{
   no warnings 'redefine';
   sub new {
      my $class=shift;
      my $re=@_==1 && _is_regexp($_[0])? $_[0]
         : @_==1 && ref($_[0]) eq 'ARRAY' && @{$_[0]}==1 && _is_regexp($_[0][0])? $_[0][0] : undef;
      return JGraft::_Node::_new($class,@_) unless defined $re;
      $class=ref($class) || $class;
      local $JGraft::Util::_construction_context={class=>$class,method=>'new',parent=>$JGraft::Util::_construction_context};
      my $inv=eval { _regexp_invlist($re) };
      my $error=$@;
      JGraft::_Node::_bad("Invalid CHARS regexp: $error") if $error;
      _freeze($inv);
      return bless {_form=>$class->forms->[0],entries=>_entries($inv),_invlist=>$inv},$class;
   }
}
sub _validate {
   my $self=shift;
   my $values=$self->{entries};
   for (my $i=0;$i+1<@$values;++$i) {
      my ($a,$b)=map _point(undef,$_),@$values[$i,$i+1];
      if (defined($a) && defined($b)) {
         $a<=$b or JGraft::_Node::_bad('CHARS range is reversed');
         ++$i;
      }
   }
}
sub _point {
   my ($exec,$v)=@_;
   return 0x10ffff unless defined $v;
   my $type=type_mask($v);
   if ($type==TYPE_NUMBER) {
      is_integer($v) && $v>=0 && $v<=0x10ffff or _bad($exec,'Invalid CHARS codepoint');
      return 0+$v;
   }
   if ($type==TYPE_STRING && length($v)==1) {
      my $cp=ord($v);
      $cp<=0x10ffff or _bad($exec,'Invalid CHARS codepoint');
      return $cp unless $exec && exists($exec->{options}{codepoint_policy})
         && (ref($exec->{options}{codepoint_policy}) || $exec->{options}{codepoint_policy} ne 'preserve');
      require JGraft::CodepointArray;
      my $scratch_base=$exec->{scratch_mem};
      local $exec->{scratch_mem}=$scratch_base;
      $exec->_scratch_set($scratch_base,JGraft::CodepointArray->_workspace($v));
      return JGraft::CodepointArray->_new($exec,$v,'character class',undef,1)->at(0);
   }
   return;
}
sub _bad {
   my ($exec,$message)=@_;
   $exec->_fail('INVALID_OPERAND',$message) if $exec;
   JGraft::_Node::_bad($message);
}
sub _charge {
   my ($exec,$n,$workspace)=@_;
   return unless $exec;
   $exec->_tick($n+1);
   if ($workspace) {
      $workspace->[1]+=64+16*$n;
      $exec->_scratch_set(@$workspace);
   }
   else { $exec->_reserve(0,64+16*$n,0) }
}
# Every interval is [start, limit), within the closed Unicode universe. Lists
# have even length, sorted boundaries, and no adjacent or overlapping intervals.
sub _combine {
   my ($a,$b,$subtract,$exec,$workspace)=@_;
   _charge($exec,@$a+@$b,$workspace);
   my ($i,$j,$in_a,$in_b,$included)=(0,0,0,0,0);
   my @out;
   while ($i<@$a || $j<@$b) {
      my $next=$j>=@$b || ($i<@$a && $a->[$i]<$b->[$j])? $a->[$i] : $b->[$j];
      if ($i<@$a && $a->[$i]==$next) { $in_a=!$in_a; ++$i }
      if ($j<@$b && $b->[$j]==$next) { $in_b=!$in_b; ++$j }
      my $member=$subtract? $in_a && !$in_b : $in_a || $in_b;
      if (!!$member != !!$included) { push @out,0+$next; $included=$member }
   }
   return \@out;
}
sub _complement { _combine([0,0x110000],$_[0],1,$_[1]) }
sub _ranges {
   my ($pairs,$exec,$workspace)=@_;
   my $n=@$pairs;
   if ($exec) { $exec->_tick($n*log($n+1)/log(2)); _charge($exec,2*$n,$workspace) }
   my @pairs=sort {$a->[0]<=>$b->[0] || $a->[1]<=>$b->[1]} @$pairs;
   my @out;
   for my $pair (@pairs) {
      my ($lo,$hi)=@$pair;
      next if $hi<0 || $lo>0x10ffff;
      $lo=0 if $lo<0; $hi=0x10ffff if $hi>0x10ffff;
      if (@out && $lo<=$out[-1]) { $out[-1]=$hi+1 if $hi+1>$out[-1] }
      else { push @out,0+$lo,1+$hi }
   }
   return \@out;
}
sub _compile {
   my ($self,$exec,$depth,$workspace)=@_;
   $exec->_enter($depth);
   my $cache=$exec->{char_classes};
   my $id=refaddr($self);
   return $cache->{$id}[1] if $cache->{$id};
   my $policy=$exec->{options}{codepoint_policy} || 'preserve';
   if (exists($self->{_invlist}) && !ref($policy) && $policy eq 'preserve') {
      $exec->_tick(scalar @{$self->{_invlist}}); $exec->_reserve(0,64,0);
      return ($cache->{$id}=[$self,_freeze($self->{_invlist})])->[1];
   }
   my ($inv,$static)=$self->_build($exec,$depth,$workspace);
   if ($static) { $exec->_reserve(0,64,0); $cache->{$id}=[$self,$inv] }
   return $inv;
}
sub _build {
   my ($self,$exec,$depth,$workspace)=@_;
   my $entries=$self->entries;
   $workspace ||= [0,0]; # Unmetered public invlist/regexp construction.
   my $floor=$workspace->[1];
   $exec->_tick(1+@$entries) if $exec;
   # Trailing switches do not change the completed set. Only its last combine
   # can escape into the application cache; all earlier builds are workspace.
   my $last=$#$entries;
   while ($last>=0 && type_mask($entries->[$last])==TYPE_BOOLEAN) {
      $exec->_tick(1) if $exec;
      --$last;
   }
   $exec->_reserve(0,96,0) if $exec && $last<0;
   my ($inv,$include,$static)=([],1,1);
   my $retained=$last<0;
   for (my $i=0;$i<@$entries;++$i) {
      if ($exec) {
         $workspace->[1]=$floor+256+($retained?0:16*@$inv);
         $exec->_scratch_set(@$workspace);
      }
      my $v=$entries->[$i];
      my $type=type_mask($v);
      if ($type==TYPE_BOOLEAN) {
         $include=$v?1:0;
         $inv=[0,0x110000] if !$i && !$include;
         next;
      }
      my $part;
      if (is_expr($v)) {
         _bad($exec,'CHARS requires an execution scope to resolve EXPR') unless $exec;
         $static=0;
         my $alias_depth=$depth;
         $v->name eq 'EXPR' or _bad($exec,'CHARS requires a common CHARS expression');
         while (is_expr($v) && $v->name eq 'EXPR') {
            $exec->_enter(++$alias_depth);
            $v=$exec->_macro($v,$alias_depth);
         }
         is_expr($v) && $v->name eq 'CHARS' or _bad($exec,'CHARS alias must resolve to CHARS');
         $part=$v->_compile($exec,$alias_depth+1,$workspace);
      }
      else {
         my $lo=_point($exec,$v);
         if (defined $lo) {
            my $hi=$i+1<@$entries? _point($exec,$entries->[$i+1]) : undef;
            if (defined $hi) { ++$i } else { $hi=$lo }
            $lo<=$hi or _bad($exec,'CHARS range is reversed');
            $part=[$lo,$hi+1];
         }
         elsif ($type==TYPE_STRING) {
            my @pairs;
            $exec->_tick(4*length($v)+1) if $exec;
            if ($exec) {
               require JGraft::CodepointArray;
               $workspace->[1]+=144*length($v)+JGraft::CodepointArray->_workspace($v);
               $exec->_scratch_set(@$workspace);
               my $view=JGraft::CodepointArray->_new($exec,$v,'character class',undef,1);
               for my $at (0..$view->size-1) { my $cp=$view->at($at); push @pairs,[$cp,$cp] }
            }
            else {
               for my $cp (unpack('U*',$v)) {
                  $cp<=0x10ffff or _bad(undef,'Invalid CHARS codepoint');
                  push @pairs,[$cp,$cp];
               }
            }
            $part=_ranges(\@pairs,$exec,$workspace);
         }
         else { _bad($exec,'Invalid CHARS entry') }
      }
      $retained=$i==$last && $static;
      $inv=_combine($inv,$part,!$include,$exec,$retained?undef:$workspace);
   }
   return ($inv,$static);
}
sub _contains {
   my ($inv,$cp,$exec)=@_;
   my ($lo,$hi)=(0,scalar @$inv);
   while ($lo<$hi) {
      $exec->_tick(1) if $exec;
      my $mid=int(($lo+$hi)/2);
      if ($inv->[$mid]<=$cp) { $lo=$mid+1 } else { $hi=$mid }
   }
   return $lo & 1;
}
sub _test {
   my ($self,$exec,$cursor,$depth)=@_;
   my $scratch_base=$exec->{scratch_mem};
   local $exec->{scratch_mem}=$scratch_base;
   # Alias-dependent lists cannot enter the cache. Their returned workspace
   # remains covered here, including recursive inclusions, through membership.
   my $inv=$self->_compile($exec,$depth,[$scratch_base,0]);
   return 0 unless $cursor->{exists};
   my $type=type_mask($cursor->{value});
   return 0 unless $type==TYPE_STRING || ($type==TYPE_NUMBER && is_integer($cursor->{value}) && $cursor->{value}>=0 && $cursor->{value}<=0x10ffff);
   my $cp=_point($exec,$cursor->{value});
   return defined($cp) && _contains($inv,$cp,$exec);
}
sub _freeze {
   my $inv=shift;
   return $inv if Internals::SvREADONLY(@$inv);
   Internals::SvREADONLY($_,1) for @$inv;
   Internals::SvREADONLY(@$inv,1);
   return $inv;
}
sub invlist {
   my $self=shift;
   return _freeze($self->{_invlist}) if exists $self->{_invlist};
   return _freeze(($self->_build(undef,0))[0]);
}
sub _entries {
   no warnings 'utf8';
   my $inv=shift;
   my (@entries,$small);
   $small='';
   for (my $i=0;$i<@$inv;$i+=2) {
      my ($lo,$limit)=@$inv[$i,$i+1];
      if ($limit-$lo>3) { push @entries,0+$lo,$limit-1 }
      else { $small.=chr($_) for $lo..$limit-1 }
   }
   push @entries,$small if length $small;
   return \@entries;
}
sub to_json_data {
   my $self=shift;
   return $self->JGraft::_Node::to_json_data(@_) unless exists $self->{_invlist};
   return ['CHARS',@{_entries($self->invlist)}];
}

# Adapted from the supplied Mock::Data::Charset parser. Only the set parser
# and Unicode-property discovery are needed; no Mock::Data dependency remains.
sub _regexp_invlist {
   my $regexp=shift;
   require re;
#__p5.28__
   my ($source,$modifiers)=re::regexp_pattern($regexp);
#__p5.8__
#   my ($source,$modifiers);
#   if (re->can('regexp_pattern')) { ($source,$modifiers)=re::regexp_pattern($regexp) }
#   else {
#      "$regexp" =~ /\A\(\?([a-z]*)(?:-[a-z]*)?:(.*)\)\z/s or die 'Cannot read regexp wrapper';
#      ($source,$modifiers)=($2,$1);
#   }
#__end__
   my %flags;
   ++$flags{$_} for split //,$modifiers;
   local $_=$source;
   pos($_)=0;
   _outside_space() if $flags{x};
   my $parsed;
   if (/\G\[/gc) { $parsed=_parse_charset(\%flags) }
   elsif (/\G\\([dDsSwWhHvVpP])/gc) {
      $parsed={}; _escape($1,$parsed);
   }
   else { die 'Expected exactly one character class' }
   _outside_space() if $flags{x};
   pos($_)==length($_) or die 'Expected exactly one character class, without anchors, groups, or quantifiers';
   # These modifiers change class membership. Let Perl resolve their semantics
   # over one Unicode character at a time, including full casefold exceptions.
#__p5.28__
   return _enumerate($regexp) if $modifiers =~ /[ial]/;
#__p5.8__
#   return _enumerate($regexp) if $modifiers =~ /[ial]/ || $parsed->{native};
#__end__
   my @pairs=map [$_,$_],@{$parsed->{codepoints} || []};
   my $ranges=$parsed->{codepoint_ranges} || [];
   for (my $i=0;$i<@$ranges;$i+=2) { push @pairs,[@$ranges[$i,$i+1]] }
   my $inv=_ranges(\@pairs);
   for my $name (@{$parsed->{classes} || []}) {
      my $part=eval { _class_invlist($name) };
      return _enumerate($regexp) if $@;
      $inv=_combine($inv,$part,0);
   }
   return $parsed->{negate}? _complement($inv) : $inv;
}
sub _outside_space { /\G(?:[ \t\r\n\f\x0b]+|\#[^\n]*(?:\n|\z))*/gc }
sub _context { 'at character '.(pos($_) || 0) }
sub _escape {
   my ($ch,$parsed)=@_;
   my %simple=(a=>7,b=>8,e=>27,f=>12,n=>10,r=>13,t=>9);
   return $simple{$ch} if exists $simple{$ch};
   if ($ch =~ /[dDsSwWhHvV]/) {
#__p5.28__
#__p5.8__
#      $parsed->{native}=1 if $]<5.018;
#      return ord($ch) if $]<5.010 && $ch =~ /[hHvV]/;
#__end__
      my %class=(d=>'Digit',s=>'Space',w=>'Word',h=>'HorizSpace',v=>'VertSpace');
      push @{$parsed->{classes}},($ch eq lc($ch)?'':'^').$class{lc $ch};
      return;
   }
   if ($ch eq 'p' || $ch eq 'P') {
      # Old Perls can resolve even built-in-looking property names through
      # caller-package functions. The original compiled regexp owns that scope.
#__p5.28__
#__p5.8__
#      $parsed->{native}=1 if $]<5.018;
#__end__
      /\G(?:\{([^}]+)\}|([A-Za-z]))/gc or die 'Invalid property escape '._context();
      my $name=defined($1)?$1:$2;
      $name =~ s/^\^// and $ch=$ch eq 'p'?'P':'p';
      push @{$parsed->{classes}},($ch eq 'P'?'^':'').$name;
      return;
   }
   if ($ch eq 'N') {
      /\G\{([^}]+)\}/gc or die 'Named character requires braces '._context();
      my $name=$1;
      return hex($1) if $name =~ /\AU\+([0-9A-Fa-f]+)\z/;
      require charnames;
      my $cp=charnames::vianame($name);
      defined($cp) or die "Unknown named character $name";
      return $cp;
   }
   if ($ch eq 'x') {
      /\G(?:\{([0-9A-Fa-f]+)\}|([0-9A-Fa-f]{1,2}))/gc or die 'Invalid hex escape '._context();
      return hex(defined($1)?$1:$2);
   }
   if ($ch eq 'o') {
      /\G\{([0-7]+)\}/gc or die 'Invalid octal escape '._context();
      return oct($1);
   }
   if ($ch =~ /[0-7]/) {
      /\G([0-7]{0,2})/gc;
      return oct($ch.$1);
   }
   if ($ch eq 'c') {
      /\G(.)/gcs or die 'Missing control character '._context();
      return ord(uc($1)) ^ 64;
   }
   return ord($ch);
}
sub _parse_charset {
   no warnings 'utf8';
   my $flags=shift;
   my %parse;
   my @range;
   /\G[ \t]*/gc if ($flags->{x} || 0)>=2;
   $parse{negate}=1 if /\G\^/gc;
   /\G[ \t]*/gc if ($flags->{x} || 0)>=2;
   push @{$parse{codepoints}},ord(']') if /\G\]/gc;
   while (1) {
      my $cp;
      if (($flags->{x} || 0)>=2 && /\G[ \t]+/gc) { next }
      if (/\G(\\|-|\[:|\])/gc) {
         my $token=$1;
         if ($token eq '\\') {
            /\G(.)/gcs or die 'Unexpected end of character class';
            $cp=_escape($1,\%parse);
         }
         elsif ($token eq '-') {
            if (@range==1) { push @range,ord('-'); next }
            $cp=ord('-');
         }
         elsif ($token eq '[:') {
#__p5.28__
#__p5.8__
#            $parse{native}=1 if $]<5.018;
#__end__
            /\G([^:]+):\]/gc or die 'Invalid POSIX character class '._context();
            my $name=$1;
            my $negative=$name =~ s/^\^//;
            $name=$name eq 'ascii'?'ASCII':ucfirst($name);
            push @{$parse{classes}},($negative?'^':'').$name;
         }
         else { last }
      }
      else { /\G(.)/gcs or die 'Unterminated character class'; $cp=ord($1) }
      if (!defined $cp) { push @{$parse{codepoints}},@range; @range=() }
      elsif (@range==1) { push @{$parse{codepoints}},$range[0]; $range[0]=$cp }
      elsif (@range==2) {
         $range[0]<=$cp or die 'Reversed character range';
         push @{$parse{codepoint_ranges}},$range[0],$cp; @range=();
      }
      else { push @range,$cp }
   }
   push @{$parse{codepoints}},@range;
   for my $cp (@{$parse{codepoints} || []},@{$parse{codepoint_ranges} || []}) {
      $cp<=0x10ffff or die 'Character class exceeds Unicode maximum';
   }
   return \%parse;
}
my %property_cache;
sub _class_invlist {
   my $name=shift;
   return _complement(_class_invlist(substr($name,1))) if substr($name,0,1) eq '^';
   return $property_cache{$name} if exists $property_cache{$name};
   require Unicode::UCD;
#__p5.28__
   my $count=Unicode::UCD::prop_invlist($name);
#__p5.8__
#   my $count=Unicode::UCD->can('prop_invlist')? Unicode::UCD::prop_invlist($name) : undef;
#__end__
   if (defined $count) {
      my @native=Unicode::UCD::prop_invlist($name);
      my @pairs;
      for (my $i=0;$i<@native;$i+=2) {
         last if $native[$i]>=0x110000;
         my $limit=defined($native[$i+1]) && $native[$i+1]<0x110000? $native[$i+1] : 0x110000;
         push @pairs,[$native[$i],$limit-1];
      }
      return $property_cache{$name}=_freeze(_ranges(\@pairs));
   }
   my $regexp=qr/\p{$name}/;
   my $inv=_enumerate($regexp);
   $property_cache{$name}=_freeze($inv) unless $name =~ /\A(?:Is|In)|::/;
   return $inv;
}
sub _enumerate {
   no warnings 'utf8';
   my $regexp=shift;
   require utf8;
   my @inv;
   my $inside=0;
   for (my $cp=0;$cp<0x110000;++$cp) {
      my $char=chr($cp);
      utf8::upgrade($char);
      # The validated class can consume only this one-character subject. Use
      # the compiled regexp directly: wrapping/recompiling it changes property
      # lookup scope on Perl 5.8.
      my $member=$char =~ $regexp?1:0;
      if ($member!=$inside) { push @inv,$cp; $inside=$member }
   }
   push @inv,0x110000 if $inside;
   return \@inv;
}

1;
