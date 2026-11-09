package JGraft::Expr::ROUND;
# VERSION
# ABSTRACT: Round decimal numbers and strings

=head1 DESCRIPTION

Round decimal digits using mode, at, shift, and as options. An integer options operand specifies shift; the value defaults to the current node.

C<mode> accepts DOWN (0), HALF_UP (1, the default), HALF_EVEN (2), CEILING (3),
FLOOR (4), or UP (5). C<at> selects decimal places; C<shift> moves the decimal
point before rounding. Both default to zero and require integers.

C<as> accepts NUM (0), INT (1), STR (2), or SIG (3). Numbers default to NUM;
strings default to STR. STR pads to exactly C<at> fractional places when
positive. SIG preserves the lesser of input precision after shifting and C<at>,
using scientific notation when necessary. Signed zero is preserved in strings.
INT requires an integral final result and can return Math::BigInt losslessly.
NUM uses native numeric storage. Invalid options fail with C<INVALID_OPERAND>;
invalid inputs or fractional INT results fail with C<INVALID_TARGET>.
See L<JGraft::Exec> for numeric conversion and range behavior.

=attribute id

The numeric operation ID, C<81>.

=attribute options

The first operand, a literal value or pre-parsed expression.

=attribute value_expr

The optional second operand, a literal value or pre-parsed expression.

=constructor new

  ->new(%attributes);
  ->new([ $options, $value_expr ]);

The operand array omits the operation name. Arrays are literal data and nested
expressions must already be nodes. ROUND permits omitting both operands.
With named attributes, C<value_expr> alone inserts an empty options object.

=constructor new_from_json_data

Construct from a decoded notation array including the operation name or ID.
Nested expressions are parsed recursively.

=method to_json_data

Return the expression in decoded JGraft notation.

=cut

require JGraft::Expr;

1;
