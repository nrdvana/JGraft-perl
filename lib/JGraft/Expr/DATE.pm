package JGraft::Expr::DATE;
# VERSION
# ABSTRACT: Match date-like things

=head1 DESCRIPTION

This object represents the L<DATE Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-date>.

The expression tests whether the current node is a valid input for CASTDATE. It takes no
operands.

=attribute id

The numeric operation ID, C<11>.

=constructor new

  ->new(%attributes);
  ->new([]);

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
