package JGraft::Action::JGRAFT;
# VERSION
# ABSTRACT: Declare metadata; top-level element

=head1 DESCRIPTION

This object represents the L<JGRAFT Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-jgraft>.

The action declares L</metadata> and executes L</actions> in that lexical scope. Constants and
common expressions come from the metadata, and the actions share a fresh STASH namespace.

=attribute id

The numeric operation ID, C<-1>.

=attribute actions

An arrayref of pre-parsed action objects.

=attribute metadata

A literal metadata hashref; const/expr declarations contain pre-parsed values.

=constructor new

  ->new(%attributes);
  ->new([ \%metadata, @actions ]);

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
