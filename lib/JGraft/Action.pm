package JGraft::Action;
# VERSION
# ABSTRACT: Object representing a JGraft action

=head1 SYNOPSIS

  use JGraft::Action;
  
  my $graft= JGraft::Action->parse($json_or_data);
  say $graft->format(pretty => 1);

=head1 DESCRIPTION

This is the base class for L<JGraft actions|https://github.com/nrdvana/JGraft#actions>.  The
method L</parse> can be used to automatically build the correct action from serialized JSON or
decoded JSON data.  To construct new actions from pre-parsed parameters, use the individual
constructors of

=over

=item L<JGraft::Action::JGRAFT>

Top level container, or define lexically scoped namespace data.

=item L<JGraft::Action::RAISE>

Log status, or abort graft.

=item L<JGraft::Action::AT>

...

=back

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

  $act_class= JGraft::Action->get_class($name_or_id);

Given an action name or ID, return the class that represents it.

=cut

our %by_name= (
   # Reference Expressions
   JGRAFT => -1,
   RAISE  =>  0,
   ...
);
our %by_id= reverse %by_name;
our %to_class= map +(
   $_           => "JGraft::Action::$_",
   $by_name{$_} => "JGraft::Action::$_",
), keys %by_name;

sub get_class {
   shift if @_ == 2 && ($_[0] eq __PACKAGE__ || $_[0]->isa(__PACKAGE__));
   @_ == 1 or croak "Expected one argument";
   $to_class{$_[0]} or croak "Unknown JGraft expression: '$_[0]'";
}

=constructor parse

  my $action= JGraft::Action->parse($json_or_data);

Decode JSON if provided a string, and then decode the data into a tree of JGraft action and
expression objects.

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
         or croak "Actions in JSON must be arrays with at least one element";
   }
   my $need_class= $to_class{$in->[0]}
      or croak "Unknown action '$in->[0]'";
   # ->parse can be called on a subclass, but should restrict to that subclass
   $class eq __PACKAGE__ || $need_class->isa($class)
      or croak "Action $need_class does not inherit from $class";
   $need_class->_parse($in);
}

=method to_json_data

  my $data= $action->to_json_data;

Return the JSON-pure data structure that represents this action, which could be passed back to
L</parse> to re-create it.

=cut

sub to_json_data {
   die "Unimplemented";
}

=method format

  my $json_text= JGraft::Action->format(%options);
  # Options:
  #   indent  => $n,    # number of spaces of indent per level
  #   wrap    => $cols, # attempt to keep content no wider than $cols

With no arguments, it defaults to C<< indent => 2, wrap => 79 >> which ideally keeps it readable
on a terminal.  This method is implemented differently by each action; each has rules that judge
how best to represent its arguments in the remaining columns.  For a more generic formatting,
you can always call C<to_json_data> and serialize it to JSON with whatever formatting you like;
however, note that a file containing JGraft should begin with the string C<< ["JGRAFT", >> 
(no whitespace) for easy detection.

=cut

sub format {
   die "unimplemented";
}

require JGraft;
require JGraft::Action::JGRAFT;
require JGraft::Action::RAISE;
require JGraft::Action::AT;
...
require JGraft::Expr;

1;
