package JGraft::Expr::ALL;
# VERSION
# ABSTRACT: Logical AND of match exprs

=head1 DESCRIPTION

This object represents the L<ALL Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-all>.

The expression requires every operand in L</match_exprs> to match. At least one operand is
required; sequence-context matches combine the constraints and capture results according to
the specification.

=attribute id

The numeric operation ID, C<5>.

=attribute match_exprs

An arrayref of match specifications containing literal data and expression objects.

=constructor new

  ->new(%attributes);
  ->new([ @match_exprs ]);

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
