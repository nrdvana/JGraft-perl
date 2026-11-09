package JGraft::Expr::LOG;
# VERSION
# ABSTRACT: Calculate logarithms

=head1 DESCRIPTION

Calculate a logarithm with a positive base other than one. The value defaults to the current node.
The value must be positive. Invalid domains and nonfinite operands fail with
C<INVALID_TARGET>. A value of one returns zero; a value equal to the base returns
one. Results use native floating point; overflow or nonzero underflow fails
with C<UNSUPPORTED_GRAFT>.

=attribute id

The numeric operation ID, C<80>.

=attribute base

The first operand, a literal value or pre-parsed expression.

=attribute value

The optional second operand, a literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $base, $value ]);

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
