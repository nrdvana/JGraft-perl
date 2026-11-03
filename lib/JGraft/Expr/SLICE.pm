package JGraft::Expr::SLICE;
# VERSION
# ABSTRACT: Return span of an array or string

=head1 DESCRIPTION

This object represents the L<SLICE Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-slice>.

The expression extracts a span from the array or string produced by L</value_expr>, using
L</ofs> and optional L</len>. Alternatively, L</config_obj> supplies capture-style bounds and
an optional path under the current node.

=attribute id

The numeric operation ID, C<57>.

=attribute config_obj

A literal value or pre-parsed expression.

=attribute len

An integer or value-context expression returning an integer.

=attribute ofs

An integer or value-context expression returning an integer.

=attribute value_expr

A literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $config_obj ]);
  ->new([ $value_expr, $ofs ]);
  ->new([ $value_expr, $ofs, $len ]);

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
