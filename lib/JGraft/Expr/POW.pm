package JGraft::Expr::POW;
# VERSION
# ABSTRACT: Calculate powers

=head1 DESCRIPTION

Raise a nonnegative base to a numeric exponent. The exponent defaults to the current node.
Zero requires a nonnegative exponent; zero to zero is one. Invalid domains
fail with C<INVALID_TARGET>. Integer exponents use exact rational arithmetic;
fractional exponents return native floating point, with decimal calculation for
exact numeric operands. Overflow or nonzero underflow
fails with C<UNSUPPORTED_GRAFT>. Nonfinite operands are rejected.

=attribute id

The numeric operation ID, C<79>.

=attribute base

The first operand, a literal value or pre-parsed expression.

=attribute exponent

The optional second operand, a literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $base, $exponent ]);

The operand array omits the operation name. Arrays are literal data and nested
expressions must already be nodes. The base is required.

=constructor new_from_json_data

Construct from a decoded notation array including the operation name or ID.
Nested expressions are parsed recursively.

=method to_json_data

Return the expression in decoded JGraft notation.

=cut

require JGraft::Expr;

1;
