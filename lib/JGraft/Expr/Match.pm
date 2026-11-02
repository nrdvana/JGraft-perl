package JGraft::Expr::Match;
# VERSION
# ABSTRACT: Parent class for Match Expressions

=head1 DESCRIPTION

This is the base class for match expressions.

=cut

use strict;
use warnings;

sub is_match { !!1 }

require JGraft::Expr::HAS;
require JGraft::Expr::IS;
require JGraft::Expr::NONE;
require JGraft::Expr::ANY;
require JGraft::Expr::ALL;
require JGraft::Expr::EXISTS;
...

1;
