package JGraft::Expr::LOCAL;
# VERSION
# ABSTRACT: Scoped overrides to select namespaces

=head1 DESCRIPTION

This object represents the L<LOCAL Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-local>.

The expression temporarily applies L</bindings> to TEMP properties or to the current node,
then evaluates L</return_value_expr>. A binding name evaluating to null rebinds NODE. All
changes are limited to this expression.

=attribute id

The numeric operation ID, C<51>.

=attribute bindings

An arrayref of pairs containing a property-name value/expression and its replacement
value/expression. A name evaluating to undef rebinds NODE; strings and numbers name TEMP
properties.

=attribute return_value_expr

A literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ (map { @$_ } @bindings), $return_value_expr ]);

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
