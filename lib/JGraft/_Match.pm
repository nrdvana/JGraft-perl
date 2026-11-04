package JGraft::_Match;
# VERSION
# ABSTRACT: Structural match state and single-node predicates
use strict;
use warnings;
no warnings 'recursion';
use Scalar::Util qw(blessed refaddr);
use JGraft::Util qw(:types type_mask is_expr is_integer is_finite);

sub _new {
   my ($class,$exec,$observable)=@_;
   $exec->_charge('mem',128);
   return bless {exec=>$exec,observable=>$observable,exact=>0,regex=>0,sequence=>undef,suppress_captures=>0,
      captures=>$exec->_new_hash(0)},$class;
}

# A cursor separates missing from null and retains a linked match-root path.
# Matching is read-only, so NODE can use a local root cell instead of repeatedly
# resolving/copying the entire path. Sequence traversal drives these same element
# tests while carrying successor positions and capture snapshots.
sub _cursor {
   my ($self,$value,$exists,$prop,$path,$anchored)=@_;
   $self->{exec}->_charge('mem',128);
   return {value=>$value,exists=>$exists,prop=>$prop,path=>$path,
      anchored=>defined($anchored)? $anchored : 1};
}

sub _test {
   my ($self,$spec,$cursor,$depth,$literal)=@_;
   my $exec=$self->{exec};
   $exec->_depth($depth);
   $exec->_step(1);
   my $before=$self->{captures};
   local $exec->{current}=[[$cursor->{value},$cursor->{exists}],[]];
   local $exec->{match_cursor}=$cursor;
   my $result=$self->_probe(sub { $self->_dispatch($spec,$cursor,$depth,$literal) });
   $self->{captures}=$before unless $result;
   return $result;
}

sub _probe {
   my ($self,$callback)=@_;
   my $exec=$self->{exec};
   my %saved=map {exists $exec->{$_}? ($_=>$exec->{$_}):()} qw(error message diagnostic);
   my $result;
   my $ok=eval { $result=$callback->(); 1 };
   my $error=$@;
   unless ($ok) {
      my $code=$exec->error;
      die $error unless blessed($error) && refaddr($error)==refaddr($exec)
         && defined($code) && ($code eq 'INVALID_TARGET' || $code eq 'INVALID_OPERAND');
      $result=0;
   }
   delete @{$exec}{qw(error message diagnostic)};
   @{$exec}{keys %saved}=values %saved;
   return $result;
}

sub _dispatch {
   my ($self,$spec,$cursor,$depth,$literal)=@_;
   my $exec=$self->{exec};
   if ($cursor->{string} && !$self->{regex_element}) {
      require JGraft::_Sequence;
      my $sequence=JGraft::_Sequence->_new($self,$cursor->{string},$cursor,0,0);
      return $sequence->_regex($spec,$depth+1,$cursor->{prop});
   }
   if (!$literal && is_expr($spec)) {
      local $exec->{expression}=$spec;
      if ($spec->_name eq 'EXPR') {
         my $body=$exec->_macro($spec,$depth+1);
         # A macro preserves matching semantics only when its root is a match
         # expression (or an alias to one). Bare structures construct values.
         return $self->_test($body,$cursor,$depth+1,0) if is_expr($body)
            && ($body->is_match || $body->_name eq 'EXPR');
         return $self->_test($exec->_eval($body,$depth+1),$cursor,$depth+1,1);
      }
      return $self->_expression($spec,$cursor,$depth) if $spec->is_match;
      return $self->_test($exec->_eval($spec,$depth+1),$cursor,$depth+1,1);
   }
   return 0 unless $cursor->{exists};
   my ($value,$type)=($cursor->{value},type_mask($spec));
   return 0 unless type_mask($value)==$type;
   if ($type==TYPE_OBJECT) {
      my $n=keys %$spec;
      $exec->_step($n);
      if ($self->{exact}) {
         $exec->_step(scalar keys %$value);
         for my $key (keys %$value) {
            $exec->_step(length($key)*.001);
            return 0 unless exists $spec->{$key};
         }
      }
      for my $key (keys %$spec) {
         $exec->_step(length($key)*.001);
         return 0 unless $self->_child($spec->{$key},$value,$key,$cursor,$depth+1,$literal);
      }
      return 1;
   }
   if ($type==TYPE_ARRAY) {
      return $self->_elements($spec,$value,0,$self->{exact},$cursor,$depth,$literal);
   }
   return 1 if $type==TYPE_NULL;
   if ($type==TYPE_DATE) {
      my ($a,$b)=($exec->_date($spec),$exec->_date($value));
      $exec->_step(16+length($a->fraction)+length($b->fraction));
      return $a->type eq $b->type && !$a->_compare($b);
   }
   if ($type==TYPE_STRING) {
      $exec->_step((length($spec)+length($value))*.001);
      return $spec eq $value;
   }
   return $spec==$value;
}

sub _child {
   my ($self,$spec,$container,$key,$parent,$depth,$literal)=@_;
   my $exec=$self->{exec};
   my $exists=$exec->_present($container,$key);
   my $cursor=$self->_cursor($exists? $exec->_child($container,$key):undef,
      $exists,$key,[$parent->{path},$key],$parent->{anchored});
   $cursor->{array}=$container if ref($container) eq 'ARRAY';
   # Sequence context never crosses a property/element descent.
   local $self->{sequence}=undef;
   return $self->_test($spec,$cursor,$depth,$literal);
}

sub _elements {
   my ($self,$specs,$value,$offset,$exact,$cursor,$depth,$literal,$suffix)=@_;
   my $size=@$value;
   return 0 if $offset<0 || $offset>$size;
   $self->{exec}->_step($offset);
   for my $i (0..$offset-1) { return 0 unless $self->{exec}->_present($value,$i) }
   unless ($literal) {
      require JGraft::_Sequence;
      my $sequence=JGraft::_Sequence->_new($self,$value,$cursor,$offset,$exact,$suffix);
      return $sequence->_array($specs,$depth+1) if $sequence->_prepare($specs,$depth+1);
   }
   return 0 if @$specs>$size-$offset+1;
   if ($suffix && $offset+@$specs<$size) {
      $self->{exec}->_step($size-$offset-@$specs);
      for my $i ($offset+@$specs..$size-1) { return 0 unless $self->{exec}->_present($value,$i) }
   }
   if ($exact && $offset+@$specs<$size) {
      $self->{exec}->_step($size-$offset-@$specs);
      for my $i ($offset+@$specs..$size-1) { return 0 if $self->{exec}->_present($value,$i) }
   }
   $self->{exec}->_step(scalar @$specs);
   for my $i (0..$#$specs) {
      return 0 unless $self->_child($specs->[$i],$value,$offset+$i,$cursor,$depth+1,$literal);
   }
   return 1;
}

sub _expression {
   my ($self,$expr,$cursor,$depth)=@_;
   my $exec=$self->{exec};
   my $name=$expr->_name;
   if ($name eq 'HAS' || $name eq 'IS') {
      local $self->{exact}=$name eq 'IS';
      return $self->_test($expr->match_spec,$cursor,$depth+1,0) unless exists $expr->{value_expr};
      my $value=$exec->_eval($expr->value_expr,$depth+1);
      my $target=$self->_cursor($value,1,undef,undef,0);
      my $pattern=$expr->match_spec;
      my $macro=0;
      while (is_expr($pattern) && $pattern->_name eq 'EXPR') {
         $macro=1;
         $exec->_depth(++$depth);
         $exec->_step(1);
         $pattern=$exec->_macro($pattern,$depth+1);
      }
      if (($macro && !is_expr($pattern)) || (is_expr($pattern) && !$pattern->is_match)) {
         return $self->_test($exec->_eval($pattern,$depth+1),$target,$depth+1,1);
      }
      return $self->_test($pattern,$target,$depth+1,0);
   }
   if ($name eq 'ANY' || $name eq 'ALL' || $name eq 'NONE') {
      local $self->{suppress_captures}=$self->{suppress_captures} || $name ne 'ALL';
      $exec->_step(scalar @{$expr->match_exprs});
      for my $arg (@{$expr->match_exprs}) {
         my $matched=$self->_test($arg,$cursor,$depth+1,0);
         return 1 if $name eq 'ANY' && $matched;
         return 0 if $name eq 'NONE' && $matched;
         return 0 if $name eq 'ALL' && !$matched;
      }
      return $name ne 'ANY';
   }
   return $cursor->{exists} if $name eq 'EXISTS';
   if ($name eq 'DATE') { return $cursor->{exists} && !!$exec->_date($cursor->{value}) }
   if ($name eq 'CHARS') {
      require JGraft::_Chars;
      return JGraft::_Chars->_test($exec,$expr,$cursor,$depth+1);
   }
   if ($name eq 'START' || $name eq 'END') {
      return 0 unless ($cursor->{array} || $cursor->{string}) && defined $cursor->{prop};
      return $name eq 'START'? $cursor->{prop}==0
         : !$cursor->{exists} && $cursor->{prop}==($cursor->{string}? $cursor->{string}{size} : @{$cursor->{array}});
   }
   if ($name eq 'SEQ' || $name eq 'SEQMIN' || $name eq 'SEQMAX' || $name eq 'REP') {
      $exec->_fail('INVALID_GRAFT',"$name is not valid at this matching position");
   }
   if ($name eq 'WITH') {
      my $temp=$exec->_new_hash(scalar keys %{$exec->{temp}[0]});
      $exec->_step(scalar keys %{$exec->{temp}[0]});
      %$temp=%{$exec->{temp}[0]};
      local $exec->{temp}=[$temp,1];
      $exec->_step(scalar @{$expr->bindings});
      for my $pair (@{$expr->bindings}) {
         my $key=$pair->[0];
         $key="$key";
         my $value=$exec->_eval($pair->[1],$depth+1);
         $exec->_put($temp,$key,$value);
      }
      return $self->_test($expr->match_expr,$cursor,$depth+1,0);
   }
   if ($name eq 'NUM') {
      my ($min,$max);
      $min=$exec->_eval($expr->min,$depth+1) if exists $expr->{min};
      $max=$exec->_eval($expr->max,$depth+1) if exists $expr->{max};
      (!defined($min) || is_finite($min)) && (!defined($max) || is_finite($max))
         or $exec->_fail('INVALID_OPERAND','NUM bounds must be finite numbers or null');
      !defined($min) || !defined($max) || $min<=$max or $exec->_fail('INVALID_OPERAND','NUM bounds are reversed');
      return $cursor->{exists} && type_mask($cursor->{value})==TYPE_NUMBER
         && (!defined($min) || $cursor->{value}>=$min) && (!defined($max) || $cursor->{value}<=$max);
   }
   if ($name eq 'ARRAY') {
      my $bound;
      $bound=$exec->_eval($expr->length,$depth+1) if exists $expr->{length};
      $bound=$exec->_eval($expr->offset,$depth+1) if exists $expr->{offset};
      if (exists($expr->{length}) || exists($expr->{offset})) {
         is_integer($bound) or $exec->_fail('INVALID_OPERAND','ARRAY length/offset must be an integer');
      }
      return 0 unless $cursor->{exists} && type_mask($cursor->{value})==TYPE_ARRAY;
      my $value=$cursor->{value};
      return 1 unless defined $bound;
      if (exists $expr->{length}) {
         return $self->{exact}? @$value==$bound : @$value>=$bound;
      }
      $bound+=@$value if $bound<0;
      return $self->_elements($expr->match_specs,$value,$bound,0,$cursor,$depth,0,$self->{exact});
   }
   if ($name eq 'STR' || $name eq 'BOOL') {
      return 0 unless $cursor->{exists} && type_mask($cursor->{value})==($name eq 'STR'?TYPE_STRING:TYPE_BOOLEAN);
      if (exists $expr->{regex_expr}) {
         require JGraft::_String;
         require JGraft::_Sequence;
         my $text=JGraft::_String->_new($exec,$cursor->{value},'subject');
         my $sequence=JGraft::_Sequence->_new($self,$text,$cursor,0,0);
         return $sequence->_regex($expr->regex_expr,$depth+1);
      }
      return 1;
   }
   $exec->_fail('UNSUPPORTED_GRAFT',"Match expression $name is not implemented");
}

1;
