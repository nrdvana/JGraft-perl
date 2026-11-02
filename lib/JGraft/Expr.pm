package JGraft::Expr;
# VERSION
# ABSTRACT: Object representing a JGraft expression

=head1 SYNOPSIS

  use JGraft::Action;
  
  my $graft= JGraft::Action->parse($json_or_data);
  say $graft->format(pretty => 1);

=head1 DESCRIPTION

This is the base class for L<JGraft expressions|https://github.com/nrdvana/JGraft#expressions>.
The method L</parse> can be used to automatically build the correct expression from serialized
JSON or decoded JSON data.  To construct new expressions from pre-parsed parameters, use the
individual constructors of:

=head2 Reference Expressions

=over

=item L<JGraft::Expr::EXPR>

Reference an element of the common subexpressions

=item L<JGraft::Expr::CAP>

Reference a path in the capture namespace

...

=back

=head2 Match Expressions

...

=head2 Function Expressions

...

=cut

#__p5.28__
use v5.28;
use experimental 'signatures';
#__p5.8__
#use strict;
#use warnings;
#__end__
use Carp;

=function get_class

  $expr_class= JGraft::Expr->get_class($name_or_id);

Given an expression name or ID, Return the class that represents it.

=cut

our %by_name= (
   # Reference Expressions
   EXPR     => -5, CAP      => -4, TEMP     => -3, STASH    => -2, CONST    => -1, NODE     =>  0,
   # Match Expressions
   HAS      =>  1, IS       =>  2, NONE     =>  3, ANY      =>  4, ALL      =>  5, EXISTS   =>  6,
   ARRAY    =>  7, STR      =>  8, NUM      =>  9, BOOL     => 10, DATE     => 11, WITH     => 12,
   SEQ      => 13, SEQMAX   => 14, SEQMIN   => 15, REP      => 16, START    => 17, END      => 18,
   CHARS    => 19,
   # Function Expressions
   CAPTURE  => 50, LOCAL    => 51, NOT      => 52, AND      => 53, OR       => 54, LENGTH   => 55,
   ...
);
our %by_id= reverse %by_name;
our %to_class= map +(
   $_           => 'JGraft::Expr::'.$_,
   $by_name{$_} => 'JGraft::Expr::'.$_,
), keys %by_name;

sub get_class {
   shift if @_ == 2 && ($_[0] eq __PACKAGE__ || $_[0]->isa(__PACKAGE__));
   @_ == 1 or croak "Expected one argument";
   $to_class{$_[0]} or croak "Unknown JGraft expression: '$_[0]'";
}

=attribute id

The ID number of this expression

=attribute is_ref

True if this expression is a reference expression

=attribute is_match

True if this expression is a match expression

=attribute is_fn

True if this expression is a function expression

=cut

# subclasses override these
sub id       { undef; }
sub is_ref   { !!0 }
sub is_match { !!0 }
sub is_fn    { !!0 }

=constructor parse

  $expr= JGraft::Expr->parse($json_or_data);

Decode JSON if provided a string, and then decode the data into a tree of JGraft expression
objects.

=cut

#__p5.28__
sub parse($class, $in) {
#__p5.8__
#sub parse {
#   my ($class, $in)= @_;
#   croak "Expected one argument" unless @_ == 2;
#__end__
   unless (ref $in eq 'ARRAY' && @$in) {
      $in= JGraft::coerce_json_to_data($in);
      ref $in eq 'ARRAY' && @$in
         or croak "Expressions in JSON must be arrays with at least one element";
   }
   my $need_class= $to_class{$in->[0]}
      or croak "Unknown expression '$in->[0]'";
   # ->parse can be called on a subclass, but should restrict to that subclass
   $class eq __PACKAGE__ || $need_class->isa($class)
      or croak "Expression $need_class does not inherit from $class";
   $need_class->_parse($in);
}

=method to_json_data

  my $data= $expr->to_json_data;

Return the JSON-compatible data structure that represents this expression, which could be passed
back to L</parse> to re-create it.

=cut

sub to_json_data {
   die "unimplemented";
}
*TO_JSON= *to_json_data; # used automatically by JSON:: libraries

=method format

  my $json_text= JGraft::Expr->format(%options);
  # Options:
  #   prefix  => $str,  # the current indent, as a string
  #   indent  => $n,    # number of spaces of indent per level
  #   wrap    => $cols, # attempt to keep content no wider than $cols

With no arguments, it defaults to C<< indent => 2, wrap => 79 >> which ideally keeps it readable
on a terminal.  This method is implemented differently by each expression; each has rules that
judge how best to represent its arguments in the remaining columns.
For a more generic formatting, you can always call C<to_json_data> and serialize it to JSON with
whatever formatting you like; however, note that a file containing JGraft should begin with the
string C<< ["JGRAFT", >> (no whitespace) for easy format detection.

=cut

sub format {
   die "unimplemented";
}

require JGraft;
require JGraft::Expr::Ref;
require JGraft::Expr::Match;
require JGraft::Expr::Fn;

1;
