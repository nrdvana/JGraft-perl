package JGraft::Expr::EXPR;
# VERSION
# ABSTRACT: An element of the common subexpressions

=head1 DESCRIPTION

This object represents the L<EXPR Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-expr>.

The expression references the common expression identified by L</name>. Common expressions are
declared by the JGRAFT action and interpreted in the context of the reference.
When used as an action path, the definition must expand to a reference expression.
The resolved namespace must satisfy that action's read/write restrictions;
these checks happen at execution because definitions and names can be scoped.

=attribute id

The numeric operation ID, C<-5>.

=attribute name

A string/integer name or value-context expression.

=constructor new

  ->new(%attributes);
  ->new([ $name ]);

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
