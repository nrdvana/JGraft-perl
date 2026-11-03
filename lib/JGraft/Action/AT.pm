package JGraft::Action::AT;
# VERSION
# ABSTRACT: Navigate to sub-node and execute sub-actions

=head1 DESCRIPTION

This object represents the L<AT Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-at>.

The action navigates to L</path> and executes L</actions> with that node as the current node.
The path must be rooted in NODE.

=attribute id

The numeric operation ID, C<1>.

=attribute actions

An arrayref of pre-parsed action objects.

=attribute path

A NODE reference, a scalar shorthand for one, or an EXPR alias resolving to NODE.

=constructor new

  ->new(%attributes);
  ->new([ $path, @actions ]);

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
