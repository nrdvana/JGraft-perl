package JGraft::Action;
# VERSION
# ABSTRACT: Object representing a JGraft action

=head1 SYNOPSIS

  use JGraft::Action;
  
  my $graft= JGraft::Action->new_from_json_data($json_data);
  say $graft->format(pretty => 1);

=head1 DESCRIPTION

This is the abstract base class for L<JGraft actions|https://github.com/nrdvana/JGraft#actions>.
The L</new_from_json_data> constructor assembles a tree of JGraft::Action and JGraft::Expr
objects from the JSON-encoded form of JGraft.  Trees can also be assembled directly from the
individual constructors of the per-action classes:

=over

=item L<JGraft::Action::JGRAFT>

Top level container, or define lexically scoped namespace data.

=item L<JGraft::Action::RAISE>

Log status, or abort graft.

=item L<JGraft::Action::AT>

Navigate to sub-node and execute sub-actions

=item L<JGraft::Action::ATSPLIT>

Navigate into SPLIT, apply actions, re-JOIN

=item L<JGraft::Action::MATCH>

Assert current node matches pattern

=item L<JGraft::Action::IF>

Choose action based on which pattern matches

=item L<JGraft::Action::COPY>

Assign-by-value to properties

=item L<JGraft::Action::MOVE>

Move existing values between properties

=item L<JGraft::Action::SPLICE>

Perform standard splice() on an array

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
use JGraft::Util 'invalid_graft';
require JGraft::_Node;
our @ISA= ('JGraft::_Node');

=method exec

  my $output= $action->exec($input, %options);

Apply this action through L<JGraft/jgexec>. Throws a L<JGraft::Exec> object on failure.

=cut

sub exec {
   require JGraft;
   JGraft::jgexec(@_);
}

=function get_class

  $act_class= JGraft::Action->get_class($name_or_id);

Given an action name or ID, return the class that represents it.

=cut

our (%by_name, %by_id, %to_class); # populated below
sub get_class {
   # can be called as class method or function
   shift if @_ == 2 && ($_[0] eq __PACKAGE__ || $_[0]->isa(__PACKAGE__));
   @_ == 1 or invalid_graft("Expected one argument");
   my $name= $_[0];
   defined $name && !ref $name or invalid_graft("Expected an action name or ID");
   $to_class{$name} or invalid_graft("Unknown JGraft action: '$name'");
}

=attribute forms

An arrayref describing the possible patterns of arguments which are accepted by the constructor.

=constructor new_from_json_data

  $action= JGraft::Action->new_from_json_data(\@array_notation);

Construct the specified action and any subtrees of actions or expressions from the JSON
representation of JGraft.  The argument must be an arrayref (since all actions are encoded
as arrays) and the first element must be a known action ID or name.  Each argument will be
interpreted according to the action's context for that argument.

=cut

#__p5.28__
sub new_from_json_data($class, $in) {
#__p5.8__
#sub new_from_json_data {
#   my ($class, $in)= @_;
#   croak "Expected one argument" unless @_ == 2;
#__end__
   local $JGraft::Util::_construction_context={class=>$class,method=>'new_from_json_data',
      parent=>$JGraft::Util::_construction_context};
   ref $in eq 'ARRAY' && @$in
      or invalid_graft("Expected an array of at least one element");
   my ($op, @args)= @$in;
   my $need_class= __PACKAGE__->get_class($op);
   # ->new_from_json_data can be called on a subclass, but should restrict to that subclass
   $class eq __PACKAGE__ || $need_class->isa($class)
      or invalid_graft("Action $need_class does not inherit from $class");
   $need_class->_construct(\@args, 1);
}

=method to_json_data

  my $data= $action->to_json_data;

Return the JSON-pure data structure that represents this action, which could be passed back to
L</new_from_json_data> to re-create it.

=cut

# to_json_data and TO_JSON are inherited from _Node

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

sub _define_action {
   my ($name, $id, @forms)= @_;
   my $class= __PACKAGE__.'::'.$name;
   $by_name{$name}= $id;
   $by_id{$id}= $name;
   $to_class{$name}= $to_class{$id}= $class;
   my %attrs;
   for my $form (@forms) {
      $attrs{$_->[0]}++ for grep defined, @{$form->{fields}||[]}, @{$form}{qw( repeat tail )};
   }
   no strict 'refs';
   @{$class.'::ISA'}= (__PACKAGE__);
   *{$class.'::id'}= sub { $id };
   *{$class.'::forms'}= sub { \@forms };
   *{$class.'::new'}= \&JGraft::_Node::_new;
   for (keys %attrs) {
      my $attr= $_;
      *{$class.'::'.$attr}= sub { $_[0]{$attr} };
   }
}


# Name, protocol ID, operand forms.
_define_action(JGRAFT => -1,
   {  fields => [[ metadata => 'metadata' ]],
      repeat =>  [ actions => 'action'],
      min => 1
   }
);
_define_action(RAISE => 0,
   {  fields => [[ level => 'level'],
                 [ message => 'message'],
                 [ data => 'value']],
      min => 2
   }
);
_define_action(AT => 1,
   {  fields => [[ path => 'node_path' ]],
      repeat =>  [ actions => 'action' ],
      min => 1
   }
);
_define_action(ATSPLIT => 2,
   {  fields => [[ path => 'node_path' ],
                 [ split_spec => 'split' ]],
      repeat =>  [ actions => 'action' ],
      min => 2
   }
);
_define_action(MATCH => 3,
   {  fields => [[ match_spec => 'match']],
      repeat =>  [ actions => 'action'],
      min => 1
   }
);
_define_action(IF => 4,
   {  repeat => [ branches => 'match','action'],
      tail   => [ else_action => 'action'],
      optional_tail => 1,
      min => 0,
   }
);
_define_action(COPY => 5,
   {  repeat => [ assignments => 'value','write_path'],
      min => 2
   }
);
_define_action(MOVE => 6,
   {  repeat => [ moves => 'move_src','move_dst'],
      min => 2
   }
);
_define_action(SPLICE => 7,
   {  fields => [[ array_elem_path => 'write_path'],
                 [ count_expr => 'nullable_int']],
      repeat =>  [ replacements => 'value'],
      min => 2
   }
);

sub JGraft::Action::ATSPLIT::_validate { &JGraft::Expr::JOIN::_validate }

require JGraft;
require JGraft::Expr;

1;
