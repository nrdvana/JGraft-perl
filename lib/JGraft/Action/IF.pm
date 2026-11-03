package JGraft::Action::IF;
# VERSION
# ABSTRACT: Choose action based on which pattern matches

=head1 DESCRIPTION

This object represents the L<IF Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-if>.

The action tests L</branches> in order and executes the action from the first matching branch.
L</else_action> supplies an optional fallback; an empty branch list without a fallback
performs no actions.

=attribute id

The numeric operation ID, C<4>.

=attribute branches

An arrayref of pairs containing a match specification and an action object.

=attribute else_action

An optional action object used when no branch matches.

=constructor new

  ->new(%attributes);
  ->new([ (map { @$_ } @branches) ]);
  ->new([ (map { @$_ } @branches), $else_action ]);

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
