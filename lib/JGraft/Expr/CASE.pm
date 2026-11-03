package JGraft::Expr::CASE;
# VERSION
# ABSTRACT: If/else that returns a value

=head1 DESCRIPTION

This object represents the L<CASE Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-case>.

The expression tests L</branches> in order and returns the value from the first matching
branch. At least one branch is required. If none match, it evaluates L</else_value_expr>, or
fails when no fallback is provided.

=attribute id

The numeric operation ID, C<66>.

=attribute branches

An arrayref of pairs containing a match specification and a literal value or expression
object. At least one pair is required.

=attribute else_value_expr

An optional fallback value or expression object. When omitted, the fallback is FAIL.

=constructor new

  ->new(%attributes);
  ->new([ (map { @$_ } @branches) ]);
  ->new([ (map { @$_ } @branches), $else_value_expr ]);

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
