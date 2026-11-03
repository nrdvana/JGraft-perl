package JGraft::Expr::NUM;
# VERSION
# ABSTRACT: Match numbers, optional ranges

=head1 DESCRIPTION

This object represents the L<NUM Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-num>.

The expression tests whether the current node is a number. L</min> and L</max> optionally
provide inclusive bounds; undef omits the corresponding bound.

=attribute id

The numeric operation ID, C<9>.

=attribute max

A numeric bound, undef, or value-context expression.

=attribute min

A numeric bound, undef, or value-context expression.

=constructor new

  ->new(%attributes);
  ->new([]);
  ->new([ $min ]);
  ->new([ $min, $max ]);

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
