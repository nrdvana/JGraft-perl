package JGraft::Expr::MAP;
# VERSION
# ABSTRACT: Transform array elements

=head1 DESCRIPTION

This object represents the L<MAP Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-map>.

The expression evaluates L</transform_expr> for each element of L</array_expr>, or of the
current node when that operand is omitted. Each input element becomes NODE during evaluation,
and the results form a new array.

=attribute id

The numeric operation ID, C<61>.

=attribute array_expr

A literal value or pre-parsed expression.

=attribute transform_expr

A literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $transform_expr ]);
  ->new([ $transform_expr, $array_expr ]);

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
