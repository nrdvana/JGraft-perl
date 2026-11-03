package JGraft::Error;
# VERSION
# ABSTRACT: JGraft exception with construction context and a text stack trace
use strict;
use warnings;
use Carp ();
use overload '""'=>'as_string', 'bool'=>sub { 1 }, fallback=>1;

sub new {
   my ($class,%attrs)=@_;
   my $self=bless {code=>$attrs{code},message=>$attrs{message},
      context=>[map +{%$_}, @{$attrs{context} || []}]},$class;
   $self->{stack_trace}=Carp::longmess($self->_description);
   return $self;
}
sub code { $_[0]{code} }
sub message { $_[0]{message} }
sub context { $_[0]{context} }
sub stack_trace { $_[0]{stack_trace} }
sub as_string { $_[0]{stack_trace} || $_[0]->_description }
sub _description {
   my $self=shift;
   my $text=$self->{code}.': '.$self->{message};
   if (@{$self->{context}}) {
      my @frames;
      for my $frame (@{$self->{context}}) {
         my $label=$frame->{class}.'->'.$frame->{method};
         $label.=' operand '.$frame->{operand} if exists $frame->{operand};
         $label.='['.$frame->{index}.']' if exists $frame->{index};
         push @frames,$label;
      }
      $text.=' (constructing '.join(' -> ',@frames).')';
   }
   return $text;
}

=head1 DESCRIPTION

An exception carrying a JGraft error code, message, and descriptive construction
context. Stringification includes the code, message, construction context, and
Carp stack trace. It is always true in boolean context.

=constructor new

  my $error= JGraft::Error->new(code => 'INVALID_GRAFT', message => 'Invalid operands');

Accepts C<code>, C<message>, and an optional C<context> array of descriptive hashes.
Captures C<Carp::longmess> immediately as text. No structural stack is retained.
Normally use L<JGraft::Util/invalid_graft> to construct and throw an error.

=attribute code

The JGraft error code.

=attribute message

The message without construction context or stack trace.

=attribute context

Construction frames, outermost first. Each contains C<class> and C<method>, with
optional C<operand> (attribute name) and C<index> (zero-based operand index).
The throw helper records descriptive scalar values, never the input or node.

=attribute stack_trace

The captured Carp diagnostic as text, including the error description.

=method as_string

Return the captured diagnostic for stringification.

=cut

1;
