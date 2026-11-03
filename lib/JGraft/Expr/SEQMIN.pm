package JGraft::Expr::SEQMIN;
# VERSION
# ABSTRACT: Named sequence, prefer shortest match

=head1 DESCRIPTION

This object represents the L<SEQMIN Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-seqmin>.

The expression matches L</match_exprs> as an adjacent sequence and optionally records its
bounds under L</capture_name>. It prefers shorter captures when resolving successful matches;
undef requests a length preference without naming a capture.

=attribute id

The numeric operation ID, C<15>.

=attribute capture_name

A string/integer capture name, undef, or value-context expression.

=attribute match_exprs

An arrayref of match specifications containing literal data and expression objects.

=constructor new

  ->new(%attributes);
  ->new([ $capture_name, @match_exprs ]);

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
