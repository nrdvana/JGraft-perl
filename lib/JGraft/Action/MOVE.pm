package JGraft::Action::MOVE;
# VERSION
# ABSTRACT: Move existing values between properties

=head1 DESCRIPTION

This object represents the L<MOVE Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-move>.

The action processes the source/destination pairs in L</moves> in order, relocating values
without copying them. An undef source supplies null; an undef destination requests deletion.
Array deletions and half-index insertions are deferred until the action finishes.

=attribute id

The numeric operation ID, C<6>.

=attribute moves

An arrayref of source/destination path pairs. Either endpoint may be undef: an undef source
supplies null, and an undef destination discards the source.

=constructor new

  ->new(%attributes);
  ->new([ map { @$_ } @moves ]);

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
