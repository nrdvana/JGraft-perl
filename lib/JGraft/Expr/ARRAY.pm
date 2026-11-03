package JGraft::Expr::ARRAY;
# VERSION
# ABSTRACT: Match arrays, specific elements

=head1 DESCRIPTION

This object represents the L<ARRAY Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-array>.

The expression tests whether the current node is an array. L</length> optionally constrains
its size; alternatively, L</offset> and L</match_specs> describe a sequence of elements to
match within it.

=attribute id

The numeric operation ID, C<7>.

=attribute length

An integer or value-context expression returning an integer.

=attribute match_specs

An arrayref of match operands.

=attribute offset

An integer or value-context expression returning an integer.

=constructor new

  ->new(%attributes);
  ->new([]);
  ->new([ $length ]);
  ->new([ $offset, @match_specs ]);

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
