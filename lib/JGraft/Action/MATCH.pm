package JGraft::Action::MATCH;
# VERSION
# ABSTRACT: Assert current node matches pattern

=head1 DESCRIPTION

This object represents the L<MATCH Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-match>.

The action tests the current node against L</match_spec>, then executes L</actions> on a
successful match. Captured sequences become the CAP namespace for those actions.

=attribute id

The numeric operation ID, C<3>.

=attribute match_spec

A match specification containing literal data and expression objects.

=attribute actions

An arrayref of pre-parsed action objects.

=constructor new

  ->new(%attributes);
  ->new([ $match_spec, @actions ]);

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
