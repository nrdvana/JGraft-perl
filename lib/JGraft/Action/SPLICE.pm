package JGraft::Action::SPLICE;
# VERSION
# ABSTRACT: Perform standard splice() on an array

=head1 DESCRIPTION

This object represents the L<SPLICE Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-splice>.

The action replaces a span beginning at L</array_elem_path>. L</count_expr> determines the
number of elements removed, and L</replacements> supplies the new values. An undef count
removes the remaining elements of the array.

=attribute id

The numeric operation ID, C<7>.

=attribute array_elem_path

A writable NODE/TEMP/STASH reference, or a scalar NODE shorthand.

=attribute count_expr

An integer, undef, or value-context expression.

=attribute replacements

An arrayref of value operands.

=constructor new

  ->new(%attributes);
  ->new([ $array_elem_path, $count_expr, @replacements ]);

Construct via attribute names or a JGraft operand arrayref using values already inflated /
decoded from JGraft JSON notation.

The operand arrayref omits the operation name. Arrays are literal data, and nested actions or
expressions must already be objects.

=constructor new_from_json_data

  ->new_from_json_data(\@jgraft_json_array);

Construct from an already-decoded JGraft JSON array. Its first element is the action name or
numeric ID; subsequent operands are recursively inflated according to their argument contexts,
including unescaping literal arrays.

=method to_json_data

Return an arrayref encoding the action in JGraft JSON notation, suitable for
new_from_json_data. Nested nodes are encoded and literal arrays are escaped.

=cut

require JGraft::Action;

1;
