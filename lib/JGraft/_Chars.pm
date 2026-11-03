package JGraft::_Chars;
# VERSION
# ABSTRACT: Ordered Unicode character class membership
use strict;
use warnings;
use Scalar::Util 'refaddr';
use JGraft::Util qw(:types type_mask is_expr is_integer);

sub _point {
   my ($exec,$v)=@_;
   return 0x10ffff unless defined $v;
   my $type=type_mask($v);
   if ($type==TYPE_NUMBER) {
      is_integer($v) && $v>=0 && $v<=0x10ffff
         or $exec->_fail('INVALID_OPERAND','Invalid CHARS codepoint');
      return $v;
   }
   if ($type==TYPE_STRING && length($v)==1) {
      return ord($v) unless exists $exec->{options}{codepoint_policy}
         && (ref($exec->{options}{codepoint_policy}) || $exec->{options}{codepoint_policy} ne 'preserve');
      require JGraft::_String;
      return JGraft::_String->_new($exec,$v,'character class')->_at(0);
   }
   return;
}
sub _compile {
   my ($class,$exec,$expr,$depth)=@_;
   $exec->_depth($depth); $exec->_step(1);
   my $cache=$exec->{char_classes} ||= {};
   my $id=refaddr($expr);
   return $cache->{$id}[1] if $cache->{$id};
   my $entries=$expr->entries;
   $exec->_step(scalar @$entries);
   $exec->_charge('mem',96+48*@$entries);
   my $set={default=>0,ops=>[]};
   my ($include,$static)=(1,1);
   for (my $i=0;$i<@$entries;++$i) {
      my $v=$entries->[$i];
      my $type=type_mask($v);
      if ($type==TYPE_BOOLEAN) {
         $include=$v?1:0;
         $set->{default}=1 if !$i && !$include;
      }
      elsif (is_expr($v)) {
         $static=0;
         my $alias_depth=$depth;
         $v->_name eq 'EXPR' or $exec->_fail('INVALID_OPERAND','CHARS requires a common CHARS expression');
         while (is_expr($v) && $v->_name eq 'EXPR') {
            $exec->_depth(++$alias_depth); $exec->_step(1);
            $v=$exec->_macro($v,$alias_depth);
         }
         is_expr($v) && $v->_name eq 'CHARS' or $exec->_fail('INVALID_OPERAND','CHARS alias must resolve to CHARS');
         push @{$set->{ops}},[$include,$class->_compile($exec,$v,$alias_depth+1)];
      }
      else {
         my $lo=_point($exec,$v);
         if (defined $lo) {
            my $hi=$i+1<@$entries? _point($exec,$entries->[$i+1]) : undef;
            if (defined $hi) { ++$i }
            else { $hi=$lo }
            $lo<=$hi or $exec->_fail('INVALID_OPERAND','CHARS range is reversed');
            push @{$set->{ops}},[$include,$lo,$hi];
         }
         elsif ($type==TYPE_STRING) {
            $exec->_step(length($v));
            $exec->_charge('mem',48*length($v));
            require JGraft::_String;
            my $view=JGraft::_String->_new($exec,$v,'character class');
            for my $i (0..$view->{size}-1) {
               my $cp=$view->_at($i);
               push @{$set->{ops}},[$include,$cp,$cp];
            }
         }
         else { $exec->_fail('INVALID_OPERAND','Invalid CHARS entry') }
      }
   }
   $cache->{$id}=[$expr,$set] if $static;
   return $set;
}
sub _contains {
   my ($class,$exec,$set,$cp,$depth)=@_;
   $exec->_depth($depth);
   $exec->_step(scalar @{$set->{ops}});
   my $result=$set->{default};
   for my $op (@{$set->{ops}}) {
      my $hit=@$op==2? $class->_contains($exec,$op->[1],$cp,$depth+1) : $cp>=$op->[1] && $cp<=$op->[2];
      $result=$op->[0] if $hit;
   }
   return $result;
}
sub _test {
   my ($class,$exec,$expr,$cursor,$depth)=@_;
   my $set=$class->_compile($exec,$expr,$depth);
   return 0 unless $cursor->{exists};
   my $type=type_mask($cursor->{value});
   return 0 unless $type==TYPE_STRING || ($type==TYPE_NUMBER && is_integer($cursor->{value}) && $cursor->{value}>=0 && $cursor->{value}<=0x10ffff);
   my $cp=_point($exec,$cursor->{value});
   return defined($cp) && $class->_contains($exec,$set,$cp,$depth+1);
}

1;
