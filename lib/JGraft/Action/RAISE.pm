package JGraft::Action::RAISE;
# VERSION
# ABSTRACT: Emit diagnostics, or reject input

=head1 DESCRIPTION

This object represents the L<RAISE Action|https://github.com/nrdvana/JGraft/SpecV1.md#act-raise>.

The action emits L</message> at L</level>, optionally attaching L</data>. The fail level
rejects the current graft attempt; message and data expressions are evaluated in value
context.

=attribute id

The numeric operation ID, C<0>.

=attribute data

A literal value or pre-parsed expression.

=attribute level

A literal info/warn/fail string or numeric ID 0/1/2.

=attribute message

A printable literal string or value-context expression.

=constructor new

  ->new(%attributes);
  ->new([ $level, $message ]);
  ->new([ $level, $message, $data ]);

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
