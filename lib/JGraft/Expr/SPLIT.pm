package JGraft::Expr::SPLIT;
# VERSION
# ABSTRACT: Split a string into an array

=head1 DESCRIPTION

This object represents the L<SPLIT Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-split>.

The expression tokenizes L</string_expr>, or the current node when omitted, according to
L</split_spec>. Separator and trimming metadata may be retained for later JOIN or ATSPLIT
operations.

=attribute id

The numeric operation ID, C<62>.

=attribute split_spec

A literal separator string, match/reference expression, or split configuration hashref.

=attribute string_expr

A literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $split_spec ]);
  ->new([ $split_spec, $string_expr ]);

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
