package JGraft::Expr::PROPS;
# VERSION
# ABSTRACT: Return properties of an object

=head1 DESCRIPTION

This object represents the L<PROPS Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-props>.

The expression returns sorted properties of L</object_expr>, or of the current node when
omitted. L</options> selects names only, name/value pairs, or parallel arrays of names and
values.

=attribute id

The numeric operation ID, C<64>.

=attribute object_expr

A literal value or pre-parsed expression.

=attribute options

An optional literal numeric value: 1 returns name/value pairs, and 2 returns parallel name
and value arrays. Without this attribute, only property names are returned.

=constructor new

  ->new(%attributes);
  ->new([]);
  ->new([ $object_expr ]);
  ->new([ $object_expr, $options ]);

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
