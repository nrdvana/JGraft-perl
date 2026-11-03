package JGraft::Expr::REP;
# VERSION
# ABSTRACT: Match repeatedly on adjacent elements

=head1 DESCRIPTION

This object represents the L<REP Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-rep>.

The expression repeats L</match_expr> between L</min> and L</max> times in sequence context.
Missing operands default to zero, unlimited repetitions, and EXISTS respectively. A maximum of
-1 means unlimited, and zero means the same count as the minimum.

=attribute id

The numeric operation ID, C<16>.

=attribute match_expr

A match specification containing literal data and expression objects.

=attribute max

An integer at least -1, or value-context expression.

=attribute min

A non-negative integer or value-context expression.

=constructor new

  ->new(%attributes);
  ->new([]);
  ->new([ $min ]);
  ->new([ $min, $max ]);
  ->new([ $min, $max, $match_expr ]);

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
