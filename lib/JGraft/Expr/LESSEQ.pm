package JGraft::Expr::LESSEQ;
# VERSION
# ABSTRACT: Less-or-equal test

=head1 DESCRIPTION

This object represents the L<LESSEQ Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-lesseq>.

The expression compares L</expr_a> and L</expr_b> for less-than-or-equal ordering, returning a
boolean. In the one-operand form the current node supplies the left side. Both values must
have the same supported type.

=attribute id

The numeric operation ID, C<73>.

=attribute expr_a

A literal value or pre-parsed expression.

=attribute expr_b

A literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $expr_b ]);
  ->new([ $expr_a, $expr_b ]);

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
