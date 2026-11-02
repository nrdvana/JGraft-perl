package JGraft::Expr::Ref;
# VERSION
# ABSTRACT: Parent class for Reference Expressions

=head1 DESCRIPTION

This is the base class for reference expressions.

=cut

use strict;
use warnings;

sub is_ref { !!1 }

require JGraft::Expr::EXPR;
require JGraft::Expr::CAP;
require JGraft::Expr::TEMP;
require JGraft::Expr::STASH;
require JGraft::Expr::CONST;
require JGraft::Expr::NODE;

1;
