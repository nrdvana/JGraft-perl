package JGraft::Expr;
# VERSION
# ABSTRACT: Object representing a JGraft expression

=head1 SYNOPSIS

  use JGraft::Expr;
  
  my $expr= JGraft::Expr->new_from_json_data(['REP', 0, -1, ['NUM']]);
  my $json_data= $expr->to_json_data;

=head1 DESCRIPTION

This is the base class for L<JGraft expressions|https://github.com/nrdvana/JGraft#expressions>.
The L</new_from_json_data> constructor assembles a tree of JGraft::Expr objects from the
JSON-encoded form of JGraft.  Trees can also be assembled directly from the individual
constructors of the per-expression classes:

=head2 Reference Expressions

=over

=item L<JGraft::Expr::EXPR>

Reference an element of the common subexpressions

=item L<JGraft::Expr::CAP>

Reference a path in the capture namespace

=item L<JGraft::Expr::TEMP>

A path in the temp namespace

=item L<JGraft::Expr::STASH>

A path in the stash namespace

=item L<JGraft::Expr::CONST>

A path in the const namespace

=item L<JGraft::Expr::NODE>

A path in the current node

=back

=head2 Match Expressions

=over

=item L<JGraft::Expr::HAS>

Partial structured match

=item L<JGraft::Expr::IS>

Exact structured match

=item L<JGraft::Expr::NONE>

Logical NOT/NOR of match exprs

=item L<JGraft::Expr::ANY>

Logical OR of match exprs

=item L<JGraft::Expr::ALL>

Logical AND of match exprs

=item L<JGraft::Expr::EXISTS>

Current node exists

=item L<JGraft::Expr::ARRAY>

Match arrays, specific elements

=item L<JGraft::Expr::STR>

Match strings, optional regex

=item L<JGraft::Expr::NUM>

Match numbers, optional ranges

=item L<JGraft::Expr::BOOL>

Match booleans

=item L<JGraft::Expr::DATE>

Match date-like things

=item L<JGraft::Expr::WITH>

Scoped overrides to TEMP namespace

=item L<JGraft::Expr::SEQ>

Match a sequence of adjacent elements

=item L<JGraft::Expr::SEQMAX>

Named sequence, prefer longest match

=item L<JGraft::Expr::SEQMIN>

Named sequence, prefer shortest match

=item L<JGraft::Expr::REP>

Match repeatedly on adjacent elements

=item L<JGraft::Expr::START>

Match at first element of array

=item L<JGraft::Expr::END>

Match at length of array

=item L<JGraft::Expr::CHARS>

Match to a set of characters

=back

=head2 Function Expressions

=over

=item L<JGraft::Expr::CAPTURE>

Match, then return captured sequences

=item L<JGraft::Expr::LOCAL>

Scoped overrides to select namespaces

=item L<JGraft::Expr::NOT>

Logical NOT of value exprs

=item L<JGraft::Expr::AND>

Logical AND of value exprs

=item L<JGraft::Expr::OR>

Logical OR of value exprs

=item L<JGraft::Expr::LENGTH>

Return length of an array or string

=item L<JGraft::Expr::CURPROP>

Get property/index of the current node.

=item L<JGraft::Expr::SLICE>

Return span of an array or string

=item L<JGraft::Expr::CONCAT>

Join spans of arrays or strings

=item L<JGraft::Expr::REDUCE>

Combine array elements

=item L<JGraft::Expr::FILTER>

Select array elements

=item L<JGraft::Expr::MAP>

Transform array elements

=item L<JGraft::Expr::SPLIT>

Split a string into an array

=item L<JGraft::Expr::JOIN>

Join, using split metadata

=item L<JGraft::Expr::PROPS>

Return properties of an object

=item L<JGraft::Expr::MKOBJ>

Construct an object from properties

=item L<JGraft::Expr::CASE>

If/else that returns a value

=item L<JGraft::Expr::FAIL>

Fail with INVALID_TARGET

=item L<JGraft::Expr::CASTBOOL>

Cast value to boolean

=item L<JGraft::Expr::CASTNUM>

Cast value to number

=item L<JGraft::Expr::CASTSTR>

Cast value to string

=item L<JGraft::Expr::CASTDATE>

Cast value to date/datetime/timestamp

=item L<JGraft::Expr::LESS>

Less-than test

=item L<JGraft::Expr::LESSEQ>

Less-or-equal test

=item L<JGraft::Expr::ADD>

Add numbers

=item L<JGraft::Expr::SUB>

Subtract numbers

=item L<JGraft::Expr::MUL>

Multiply numbers

=item L<JGraft::Expr::DIV>

Divide numbers

=item L<JGraft::Expr::MOD>

Calculate Modulus

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
use JGraft::Util qw(is_expr type_mask invalid_graft);
require JGraft::_Node;
our @ISA= ('JGraft::_Node');

@JGraft::Expr::Ref::ISA  = (__PACKAGE__);
@JGraft::Expr::Match::ISA= (__PACKAGE__);
@JGraft::Expr::Fn::ISA   = (__PACKAGE__);

=function get_class

  $expr_class= JGraft::Expr->get_class($name_or_id);

Given an expression name or ID, Return the class that represents it.

=cut

our (%by_name, %by_id, %to_class); # populated below
sub get_class {
   # optionally called as a class method
   shift if @_ == 2 && ($_[0] eq __PACKAGE__ || $_[0]->isa(__PACKAGE__));
   @_ == 1 or invalid_graft("Expected one argument");
   my $name= $_[0];
   defined $name && !ref $name or invalid_graft("Expected an expression name or ID");
   $to_class{$name} or invalid_graft("Unknown JGraft expression: '$name'");
}

=attribute id

The ID number of this expression

=attribute returns

The declared result-type bitmask for a concrete class: null=1, boolean=2,
number=4, string=8, array=16, object=32, and date=64. Zero means no successful
result; 127 permits any type. Class calls return the declared capabilities;
instance calls may refine these using their operands. LOCAL instances return
the type of their return-value operand, while LOCAL class calls return 127.

=attribute forms

An arrayref describing the concrete class's supported positional operand forms.
The constructor uses these entries for argument binding and validation.

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
sub JGraft::Expr::Ref::is_ref { !!1 }
sub JGraft::Expr::Match::is_match { !!1 }
sub JGraft::Expr::Fn::is_fn { !!1 }

=constructor new

  my $expr= JGraft::Expr::NODE->new(['title']);
  my $expr= JGraft::Expr::NODE->new(path => ['title']);

Concrete classes accept an arrayref of operands, without an operation name,
or name/value attributes documented by that class. Arrays in constructor
operands are literal, while nested expressions must already be objects.
Repeated operands use arrayref attributes; alternating operands use an arrayref
of two-element arrayrefs. Optional attributes are omitted unless supplied,
with positional defaults inserted when needed to reach a later attribute.

C<new_from_json_data> accepts the full notation array, including its name or ID, parses
nested expressions, and unescapes literal arrays. Neither construction path
evaluates expressions. Intrinsic operand restrictions are checked, while
target-dependent failures and guarded runtime errors remain for execution.

=constructor new_from_json_data

  $expr= JGraft::Expr->new_from_json_data(\@array_notation);

Construct the specified expression and its expression subtrees from already-decoded
JGraft JSON data. The argument must be an arrayref whose first element is a known
expression name or numeric ID. Each operand is interpreted in its declared argument
context, recursively inflating expressions and unescaping literal arrays.

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
      or invalid_graft("Expression $need_class does not inherit from $class");
   $need_class->_construct(\@args, 1);
}

=method to_json_data

  my $data= $expr->to_json_data;

Return the JSON-compatible data structure that represents this expression, which could be passed
back to L</new_from_json_data> to re-create it.

=cut

# to_json_data and TO_JSON are inherited from _Node

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

sub _define_expr {
   my ($name, $id, $returns, @forms)= @_;
   $by_name{$name}= $id;
   $by_id{$id}= $name;
   my $class= __PACKAGE__.'::'.$name;
   $to_class{$name}= $to_class{$id}= $class;
   my %attrs;
   for my $form (@forms) {
      $attrs{$_->[0]}++ for grep defined, @{$form->{fields}||[]}, @{$form}{qw( repeat tail )};
   }
   no strict 'refs';
   @{$class.'::ISA'}= $id <= 0? 'JGraft::Expr::Ref'
                    : $id < 50? 'JGraft::Expr::Match'
                    : 'JGraft::Expr::Fn';
   # TODO: use Class::XSAccessor if available
   *{$class.'::new'}= \&JGraft::_Node::_new;
   *{$class.'::id'}= sub { $id };
   *{$class.'::returns'}= sub { $returns } unless defined &{$class.'::returns'};
   *{$class.'::forms'}= sub { \@forms };
   for (keys %attrs) {
      my $attr= $_;
      *{$class.'::'.$attr}= sub { $_[0]{$attr} };
   }
}

# Name, protocol ID, potential result types, operand forms.
_define_expr(EXPR => -5, 127,
   {  fields => [[ name => 'name' ]],
      min => 1
   }
);
_define_expr(CAP => -4, 127,
   {  repeat => [ path => 'value' ],
      min => 0
   }
);
_define_expr(TEMP => -3, 127,
   {  repeat => [ path => 'value' ],
      min => 1
   }
);
_define_expr(STASH => -2, 127,
   {  repeat => [ path => 'value' ],
      min => 0
   }
);
_define_expr(CONST => -1, 127,
   {  repeat => [ path => 'value' ],
      min => 0
   }
);
_define_expr(NODE => 0, 127,
   {  repeat => [ path => 'value' ],
      min => 0
   }
);
_define_expr(HAS => 1, 2,
   {  fields => [[ match_spec => 'match' ]],
      min => 1
   },
   {  fields => [[ value_expr => 'value' ],
                 [ match_spec => 'match' ]],
      min => 2
   }
);
_define_expr(IS => 2, 2,
   {  fields => [[ match_spec => 'match' ]],
      min => 1
   },
   {  fields => [[ value_expr => 'value' ],
                 [ match_spec => 'match' ]],
      min => 2
   }
);
_define_expr(NONE => 3, 2,
   {  repeat => [ match_exprs => 'match' ],
      min => 0
   }
);
_define_expr(ANY => 4, 2,
   {  repeat => [ match_exprs => 'match' ],
      min => 1
   }
);
_define_expr(ALL => 5, 2,
   {  repeat => [ match_exprs => 'match' ],
      min => 1
   }
);
_define_expr(EXISTS => 6, 2,
   {  fields => [],
      min => 0
   }
);
_define_expr(ARRAY => 7, 2,
   {  fields => [],
      min => 0
   },
   {  fields => [[ length => 'int' ]],
      min => 1
   },
   {  fields => [[ offset => 'int' ]],
      repeat =>  [ match_specs => 'match' ],
      min => 2
   }
);
_define_expr(STR => 8, 2,
   {  fields => [[ regex_expr => 'regex' ]],
      min => 0
   }
);
_define_expr(NUM => 9, 2,
   {  fields => [[ min => 'bound', undef ],
                 [ max => 'bound' ]],
      min => 0
   }
);
_define_expr(BOOL => 10, 2,
   {  fields => [],
      min => 0
   }
);
_define_expr(DATE => 11, 2,
   {  fields => [],
      min => 0
   }
);
_define_expr(WITH => 12, 2,
   {  repeat => [ bindings => 'prop', 'value' ],
      tail =>   [ match_expr => 'match' ],
      min => 3
   }
);
_define_expr(SEQ => 13, 2,
   {  repeat => [ match_exprs => 'match' ],
      min => 0
   }
);
_define_expr(SEQMAX => 14, 2,
   {  fields => [[ capture_name => 'capture_name' ]],
      repeat =>  [ match_exprs => 'match' ],
      min => 1
   }
);
_define_expr(SEQMIN => 15, 2,
   {  fields => [[ capture_name => 'capture_name' ]],
      repeat =>  [ match_exprs => 'match' ],
      min => 1
   }
);
_define_expr(REP => 16, 2,
   {  fields => [[ min => 'nonneg_int', 0 ],
                 [ max => 'rep_max', -1 ],
                 [ match_expr => 'match' ]],
      min => 0
   }
);
_define_expr(START => 17, 2,
   {  fields => [],
      min => 0
   }
);
_define_expr(END => 18, 2,
   {  fields => [],
      min => 0
   }
);
_define_expr(CHARS => 19, 2,
   {  repeat => [ entries => 'chars' ],
      min => 0
   }
);
_define_expr(CAPTURE => 50, 34,
   {  fields => [[ match_expr => 'match' ]],
      min => 1
   }
);
_define_expr(LOCAL => 51, 127,
   {  repeat => [ bindings => 'local_prop', 'value' ],
      tail =>   [ return_value_expr => 'value' ],
      min => 1
   }
);
_define_expr(NOT => 52, 2,
   {  repeat => [ value_exprs => 'value' ],
      min => 1
   }
);
_define_expr(AND => 53, 2,
   {  repeat => [ value_exprs => 'value' ],
      min => 1
   }
);
_define_expr(OR => 54, 2,
   {  repeat => [ value_exprs => 'value' ],
      min => 1
   }
);
_define_expr(LENGTH => 55, 4,
   {  fields => [[ value_expr => 'value' ]],
      min => 0
   }
);
_define_expr(CURPROP => 56, 13,
   {  fields => [],
      min => 0
   }
);
_define_expr(SLICE => 57, 24,
   {  fields => [[ config_obj => 'value' ]],
      min => 1
   },
   {  fields => [[ value_expr => 'value' ],
                 [ ofs => 'int' ],
                 [ len => 'int' ]],
      min => 2
   }
);
_define_expr(CONCAT => 58, 24,
   {  repeat => [ value_exprs => 'value' ],
      min => 1
   }
);
_define_expr(REDUCE => 59, 127,
   {  fields => [[ reduce_expr => 'value' ],
                 [ temp_prop => 'numeric_prop' ],
                 [ initial_value => 'value' ],
                 [ array_expr => 'value' ]],
      min => 3
   }
);
_define_expr(FILTER => 60, 16,
   {  fields => [[ match_expr => 'match' ],
                 [ array_expr => 'value' ]],
      min => 1
   }
);
_define_expr(MAP => 61, 16,
   {  fields => [[ transform_expr => 'value' ],
                 [ array_expr => 'value' ]],
      min => 1
   }
);
_define_expr(SPLIT => 62, 16,
   {  fields => [[ split_spec => 'split' ],
                 [ string_expr => 'value' ]],
      min => 1
   }
);
_define_expr(JOIN => 63, 8,
   {  fields => [[ split_spec => 'split' ],
                 [ array_expr => 'value' ]],
      min => 1
   }
);
_define_expr(PROPS => 64, 16,
   {  fields => [[ object_expr => 'value' ],
                 [ options => 'options' ]],
      min => 0
   }
);
_define_expr(MKOBJ => 65, 32,
   {  fields => [[ prop_array_expr => 'value' ]],
      min => 1
   },
   {  repeat => [ value_exprs => 'value' ],
      min => 0
   }
);
_define_expr(CASE => 66, 127,
   {  repeat => [ branches => 'match', 'value' ],
      tail =>   [ else_value_expr => 'value' ],
      optional_tail => 1,
      min => 2
   }
);
_define_expr(FAIL => 67, 0,
   {  fields => [],
      min => 0
   }
);
_define_expr(CASTBOOL => 68, 2,
   {  fields => [[ value_expr => 'value' ]],
      min => 0
   }
);
_define_expr(CASTNUM => 69, 4,
   {  fields => [[ value_expr => 'value' ]],
      min => 0
   }
);
_define_expr(CASTSTR => 70, 8,
   {  fields => [[ value_expr => 'value' ]],
      min => 0
   }
);
_define_expr(CASTDATE => 71, 64,
   {  fields => [[ value_expr => 'value' ]],
      min => 0
   }
);
_define_expr(LESS => 72, 2,
   {  fields => [[ expr_b => 'value' ]],
      min => 1
   },
   {  fields => [[ expr_a => 'value' ],
                 [ expr_b => 'value' ]],
      min => 2
   }
);
_define_expr(LESSEQ => 73, 2,
   {  fields => [[ expr_b => 'value' ]],
      min => 1
   },
   {  fields => [[ expr_a => 'value' ],
                 [ expr_b => 'value' ]],
      min => 2
   }
);
_define_expr(ADD => 74, 4,
   {  repeat => [ value_exprs => 'value' ],
      min => 0
   }
);
_define_expr(SUB => 75, 4,
   {  fields => [[ value_expr1 => 'value' ],
                 [ value_expr2 => 'value' ]],
      min => 2
   }
);
_define_expr(MUL => 76, 4,
   {  repeat => [ value_exprs => 'value' ],
      min => 0
   }
);
_define_expr(DIV => 77, 4,
   {  fields => [[ value_expr1 => 'value' ],
                 [ value_expr2 => 'value' ]],
      min => 2
   }
);
_define_expr(MOD => 78, 4,
   {  fields => [[ value_expr1 => 'value' ],
                 [ value_expr2 => 'value' ]],
      min => 2
   }
);

sub JGraft::Expr::LOCAL::returns {
   my $self=shift;
   return ref($self)? type_mask($self->{return_value_expr}) : 127;
}

sub JGraft::Expr::Ref::_validate {
   my $self=shift;
   JGraft::_Node::_path_elements($self->{path},1) if exists $self->{path};
}

sub JGraft::Expr::TEMP::_validate {
   my $self=shift;
   JGraft::Expr::Ref::_validate($self);
   @{$self->{path}} or JGraft::_Node::_bad('TEMP requires a path');
}

sub JGraft::Expr::NUM::_validate {
   my $self=shift;
   return unless defined $self->{min} && defined $self->{max}
      && !is_expr($self->{min}) && !is_expr($self->{max});
   $self->{min} <= $self->{max} or JGraft::_Node::_bad('NUM bounds are reversed');
}

sub JGraft::Expr::REP::_validate {
   my $self=shift;
   return unless exists $self->{min} && exists $self->{max}
      && !is_expr($self->{min}) && !is_expr($self->{max});
   $self->{max} <= 0 || $self->{max} >= $self->{min}
      or JGraft::_Node::_bad('REP bounds are reversed');
}

sub JGraft::Expr::CHARS::_validate {
   my $self=shift;
   my $values=$self->{entries};
   for (my $i=0; $i+1<@$values; ++$i) {
      my ($a,$b)=map _codepoint($_), @$values[$i,$i+1];
      if (defined $a && defined $b) {
         $a <= $b or JGraft::_Node::_bad('CHARS range is reversed');
         ++$i;
      }
   }
}

sub _codepoint {
   my $v=shift;
   return 0x10ffff unless defined $v;
   return if is_expr($v);
   my $type=type_mask($v);
   return $v if $type==4;
   return ord($v) if $type==8 && length($v)==1;
   return;
}

sub JGraft::Expr::JOIN::_validate {
   my $self=shift;
   my $split=$self->{split_spec};
   if (is_expr($split) && $split->is_match) {
      JGraft::_Node::_bad('Regex joining requires a default separator');
   }
   if (ref($split) eq 'HASH' && is_expr($split->{sep}) && $split->{sep}->is_match) {
      exists $split->{keep} || exists $split->{default}
         or JGraft::_Node::_bad('Regex joining requires a default separator');
      JGraft::_Node::_expect($split->{default},8,'string separator') unless exists $split->{keep};
   }
}

require JGraft;

1;
