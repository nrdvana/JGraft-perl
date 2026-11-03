package JGraft::Action::COPY;
# VERSION
# ABSTRACT: Assign-by-value to properties

=head1 DESCRIPTION

This object represents the L<COPY Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-copy>.

The action evaluates each value/path pair in L</assignments> and assigns the constructed value
to its destination. Pairs are processed in order, so each pair sees the effects of earlier
assignments.

=attribute id

The numeric operation ID, C<5>.

=attribute assignments

An arrayref of pairs containing a literal value or expression object followed by a writable
path. Values are constructed and assigned in pair order.

=constructor new

  ->new(%attributes);
  ->new([ map { @$_ } @assignments ]);

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
