package JGraft::Util;
# VERSION
# ABSTRACT: Shared JGraft type predicates
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util 'blessed';
use B ();
use JSON::PP ();
our @EXPORT_OK= qw(type_mask is_finite is_integer is_expr is_action);

sub type_mask {
   my $v= shift;
   return 1 unless defined $v;
   return 2 if JSON::PP::is_bool($v);
   return $v->_result_types if is_expr($v);
   return 16 if ref $v eq 'ARRAY';
   return 32 if ref $v eq 'HASH';
   return 0 if ref $v;
   my $flags= B::svref_2object(\$v)->FLAGS;
   return ($flags & (B::SVp_IOK() | B::SVp_NOK())) && !($flags & B::SVp_POK())? 4 : 8;
}
sub is_finite {
   my $v= shift;
   return 0 if ref $v || type_mask($v) != 4;
   return ($v - $v) == 0;
}
sub is_integer { my $v= shift; is_finite($v) && $v == int($v) }
sub is_expr { blessed($_[0]) && $_[0]->isa('JGraft::Expr') }
sub is_action { blessed($_[0]) && $_[0]->isa('JGraft::Action') }

=head1 DESCRIPTION

Optional exports shared by the node constructors and executor. Numeric predicates
inspect copies of scalar values, preserving numeric/string distinctions in input.

=function type_mask

Return the JSON type bitmask: null=1, boolean=2, number=4, string=8, array=16,
object=32. An expression object returns its possible result types (including
date=64); other references return zero. This does not validate container contents.

=function is_finite

True for a finite numeric scalar. Strings, booleans, objects, infinity, and NaN
return false without numeric coercion of strings.

=function is_integer

True for a finite numeric scalar with no fractional part.

=function is_expr

True for a JGraft expression object.

=function is_action

True for a JGraft action object.

=cut

1;
