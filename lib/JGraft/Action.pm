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
   if (ref $name) {
      my $type=JGraft::Util::type_mask($name);
      if ($type==JGraft::Util::TYPE_NUMBER() && JGraft::Util::is_integer($name)) {
         my $id=int($name); $name="$id";
      }
      $name="$name" if $type==JGraft::Util::TYPE_STRING();
   }
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

  my $json_text= $action->format(%options);
  # Options:
  #   prefix  => $str,  # the current indent, as a string
  #   indent  => $n,    # number of spaces of indent per level
  #   wrap    => $cols, # attempt to keep content no wider than $cols
  #   ids     => 1,     # numeric IDs instead of names (default: 0)
  #   close   => 'inline', # or 'newline' (default)

Returns JSON text without a trailing newline. Defaults are C<< indent => 2 >>,
C<< wrap => 79 >>, an empty whitespace prefix, directive names, and closing
brackets on their own lines for wrapped containers. C<< close => 'inline' >>
attaches those brackets to the final argument instead.

Nested directives with more than one argument start on new lines. Logical pairs
such as COPY assignments and IF branches share a line when they fit. Arguments
reserve one column for their following comma or closing bracket. If wrapping
would leave fewer than 40 columns after indentation, the local width doubles
until there is room; arguments are rendered again under that wider constraint.
C<< wrap => 0 >> disables width-driven wrapping, while structural breaks remain.
Long scalar strings are never split. Object keys are sorted for stable output.

C<< indent => 0 >> selects compact JSON: no optional spaces, indentation, or
structural breaks. Width wrapping inserts newlines only between complete JSON
tokens; width doubling and the closing-bracket style are ignored in this mode.
With C<< indent => 0, wrap => 0 >>, the result is entirely minified. String contents
remain unchanged. The whitespace prefix is ignored in compact mode.

The prefix is included on every line. With the default empty prefix and names,
the output begins C<["JGRAFT",> for a JGRAFT node. Numeric IDs change actual
directives only; literal strings and array escaping are preserved. The
L<jg-format> command provides the same formatting options for UTF-8 graft files.
It also accepts arbitrary JSON, formatting valid embedded grafts as directives
and invalid ones as ordinary JSON; see L<JGraft/jgformat>.

=cut

sub format {
   require JGraft::_Format;
   return JGraft::_Format->format(@_);
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
   my @operands=sort keys %attrs;
   *{$class.'::_operand_fields'}= sub { (ref($_[0]) || $_[0]) eq $class?\@operands:undef };
   *{$class.'::id'}= sub { $id };
   *{$class.'::name'}= sub { $name };
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

# ATSPLIT needs the same split_spec validation as the JOIN expression.
sub JGraft::Action::ATSPLIT::_validate { &JGraft::Expr::JOIN::_validate }

require JGraft;
require JGraft::Expr;

1;
