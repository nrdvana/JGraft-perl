package JGraft::Expr::MKOBJ;
# VERSION
# ABSTRACT: Construct an object from properties

=head1 DESCRIPTION

This object represents the L<MKOBJ Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-mkobj>.

The expression constructs an object from alternating name/value operands, parallel arrays of
names and values, or one array of property pairs. Names must evaluate to distinct strings. The
interpretation depends on evaluated operand types as well as their count.

=attribute id

The numeric operation ID, C<65>.

=attribute prop_array_expr

A literal array of property-pair arrays, or an expression producing that array.

=attribute value_exprs

An arrayref of alternating name/value operands, or the two array-producing operands of the
parallel-array form. Operands are literal values or expression objects.

=constructor new

  ->new(%attributes);
  ->new([ $name_expr, $value_expr ]);
  ->new([ @value_exprs ]);
  ->new([ $name_array_expr, $value_array_expr ]);
  ->new([ $prop_array_expr ]);

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
