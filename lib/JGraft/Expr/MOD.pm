package JGraft::Expr::MOD;
# VERSION
# ABSTRACT: Calculate Modulus

=head1 DESCRIPTION

This object represents the L<MOD Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-mod>.

The expression calculates the modulus of L</value_expr1> by L</value_expr2>. Both operands
must produce numbers. The result follows the divisor's sign, as specified for JGraft modulus.

=attribute id

The numeric operation ID, C<78>.

=attribute value_expr1

A literal value or pre-parsed expression.

=attribute value_expr2

A literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $value_expr1, $value_expr2 ]);

Construct via attribute names or a JGraft operand arrayref using values already inflated /
decoded from JGraft JSON notation.

The operand arrayref omits the operation name. Arrays are literal data, and nested actions or
expressions must already be objects.

=constructor new_from_json_data

  ->new_from_json_data(\@jgraft_json_array);

Construct from an already-decoded JGraft JSON array. Its first element is the expression name
or numeric ID; subsequent operands are recursively inflated according to their argument
contexts, including unescaping literal arrays.

=method to_json_data

Return an arrayref encoding the expression in JGraft JSON notation, suitable for
new_from_json_data. Nested nodes are encoded and literal arrays are escaped.

=cut

require JGraft::Expr;

1;
