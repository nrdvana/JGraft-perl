package JGraft::Expr::Match;
# VERSION
# ABSTRACT: Parent class for Function Expressions

=head1 DESCRIPTION

This is the base class for function expressions.

=cut

use strict;
use warnings;

sub is_fn { !!1 }

require JGraft::Expr::CAPTURE;
require JGraft::Expr::LOCAL;
require JGraft::Expr::NOT;
require JGraft::Expr::AND;
require JGraft::Expr::OR;
require JGraft::Expr::LENGTH;
...

1;
