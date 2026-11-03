package JGraft::Expr::WITH;
# VERSION
# ABSTRACT: Scoped overrides to TEMP namespace

=head1 DESCRIPTION

This object represents the L<WITH Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-with>.

The expression temporarily overlays TEMP properties using L</bindings>, then evaluates
L</match_expr> in match context. Each binding is visible to subsequent bindings, and the
previous TEMP scope is restored afterward.

=attribute id

The numeric operation ID, C<12>.

=attribute bindings

An arrayref of pairs containing a literal TEMP property name (a string or integer) and a
literal value or expression object. Bindings are applied in order.

=attribute match_expr

A match specification containing literal data and expression objects.

=constructor new

  ->new(%attributes);
  ->new([ (map { @$_ } @bindings), $match_expr ]);

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
