package JGraft::Util;
# VERSION
# ABSTRACT: Shared JGraft type predicates
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util 'blessed';
use B ();
use JSON::PP ();
use constant {
   TYPE_NONE    => 0,
   TYPE_NULL    => 1,
   TYPE_BOOLEAN => 2,
   TYPE_NUMBER  => 4,
   TYPE_STRING  => 8,
   TYPE_ARRAY   => 16,
   TYPE_OBJECT  => 32,
   TYPE_DATE    => 64,
   TYPE_ANY     => 127,
};
our @EXPORT_OK= qw(type_mask is_finite is_integer is_expr is_action invalid_graft);
our %EXPORT_TAGS=(types=>[qw(TYPE_NONE TYPE_NULL TYPE_BOOLEAN TYPE_NUMBER
   TYPE_STRING TYPE_ARRAY TYPE_OBJECT TYPE_DATE TYPE_ANY)]);
push @EXPORT_OK,@{$EXPORT_TAGS{types}};
our $_construction_context;

sub invalid_graft {
   my @context;
   for (my $frame=$_construction_context; $frame; $frame=$frame->{parent}) {
      push @context,{map {$_=>$frame->{$_}} grep $_ ne 'parent', keys %$frame};
   }
   require JGraft::Error;
   die JGraft::Error->new(code=>'INVALID_GRAFT',message=>join('',@_),context=>[reverse @context]);
}

sub type_mask {
   my $v= shift;
   return TYPE_NULL unless defined $v;
   return TYPE_BOOLEAN if JSON::PP::is_bool($v);
   return $v->returns if is_expr($v);
   return TYPE_DATE if blessed($v) && ($v->isa('JGraft::Date') || $v->isa('Time::Piece') || $v->isa('DateTime'));
   return TYPE_ARRAY if ref $v eq 'ARRAY';
   return TYPE_OBJECT if ref $v eq 'HASH';
   return TYPE_NONE if ref $v;
   my $flags= B::svref_2object(\$v)->FLAGS;
   return ($flags & (B::SVp_IOK() | B::SVp_NOK())) && !($flags & B::SVp_POK())? TYPE_NUMBER : TYPE_STRING;
}
sub is_finite {
   my $v= shift;
   return 0 if ref $v || type_mask($v) != TYPE_NUMBER;
   return ($v - $v) == 0;
}
sub is_integer { my $v= shift; is_finite($v) && $v == int($v) }
sub is_expr { blessed($_[0]) && $_[0]->isa('JGraft::Expr') }
sub is_action { blessed($_[0]) && $_[0]->isa('JGraft::Action') }

=head1 DESCRIPTION

Optional exports shared by the node constructors and executor. Numeric predicates
inspect copies of scalar values, preserving numeric/string distinctions in input.

=head1 TYPE CONSTANTS

  use JGraft::Util qw(:types type_mask);
  my $allowed= TYPE_NULL | TYPE_NUMBER;

The C<:types> export tag supplies these Perl constants; each may also be imported
individually. Combine type bits with C<|>. Their numeric values are unchanged:

  TYPE_NONE       0    No possible result, or an unrecognized reference
  TYPE_NULL       1
  TYPE_BOOLEAN    2
  TYPE_NUMBER     4
  TYPE_STRING     8
  TYPE_ARRAY     16
  TYPE_OBJECT    32
  TYPE_DATE      64
  TYPE_ANY      127    All supported type bits

=for Pod::Coverage TYPE_[A-Z]+

=function invalid_graft

  invalid_graft('Invalid operand: ', $description);

Throw a L<JGraft::Error> with code C<INVALID_GRAFT>, concatenating the message
arguments. Captures the current construction context and a text-only Carp stack
trace. Context is empty when called outside node construction. No exports are
enabled by default.

=function type_mask

Return the JSON type bitmask: null=1, boolean=2, number=4, string=8, array=16,
object=32. An expression object returns its possible result types (including
date=64); other references return zero. This does not validate container contents.
Use the named L</TYPE CONSTANTS> when checking or combining these bits.

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
