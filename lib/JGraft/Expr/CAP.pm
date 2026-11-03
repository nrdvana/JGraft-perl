package JGraft::Expr::CAP;
# VERSION
# ABSTRACT: A path in the capture namespace

=head1 DESCRIPTION

This object represents the L<CAP Expression|https://github.com/nrdvana/JGraft/SpecV1.md#ex-cap>.

The expression reads the capture namespace at L</path>. An empty path refers to the entire
namespace; captured sequences expose their path, offset, length, and limit.

=attribute id

The numeric operation ID, C<-4>.

=attribute path

An arrayref of path selectors: property-name strings, numeric array indices, or value-context
expression objects. An expression may produce an array of selectors to expand into the path.

=constructor new

  ->new(%attributes);
  ->new([ @path ]);

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
