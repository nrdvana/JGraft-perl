package JGraft::Expr::FILTER;
# VERSION
# ABSTRACT: Select array elements

=head1 DESCRIPTION

This object represents the L<FILTER Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-filter>.

The expression selects elements matching L</match_expr> from L</array_expr>, or from the
current node when that operand is omitted. Each element becomes NODE while its match is
tested.

=attribute id

The numeric operation ID, C<60>.

=attribute array_expr

A literal value or pre-parsed expression.

=attribute match_expr

A match specification containing literal data and expression objects.

=constructor new

  ->new(%attributes);
  ->new([ $match_expr ]);
  ->new([ $match_expr, $array_expr ]);

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
