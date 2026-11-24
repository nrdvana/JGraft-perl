package JGraft::JSON::Cursor;
# VERSION
# ABSTRACT: Position and layout attributes of a node being encoded by JGraft::JSON
use strict;
use warnings;
use Carp 'croak';

# Fields:
#    value name idx parent depth indent   position (read-only)
#    state cb leaves                      callback bookkeeping; cb is for descendants
#    sortkeys sort                        key order as assigned, and compiled
#    layout prefix suffix emit            assigned, or cached from a lazy read
#    auto built                           lazily read layout; emit was lazily read
#    before after                         assigned comments
#    rec                                  retained gaps for reading comments
#    last cindent                         last member, and its container's line indent
#    lock                                 1: all but suffix are final, 2: suffix too
#    _pre _suf _lay _emit                 lazy builders, present only while the
#                                         encoder is positioned on this node; they
#                                         receive the cursor to avoid a cycle
sub _new {
   my ($class, $parent, $idx, $name, $value)= @_;
   return bless {
      value => $value, idx => $idx, name => $name, parent => $parent, lock => 0,
      depth => $parent? $parent->{depth}+1 : 0,
      leaves => $parent? $parent->{leaves} : 1,
      state => $parent? $parent->{state} : undef,
      cb => $parent && $parent->{cb},
      sortkeys => $parent && $parent->{sortkeys}, sort => $parent && $parent->{sort},
   }, $class;
}
sub _writable {
   my ($c, $bit, $what)= @_;
   $c->{lock} & $bit and croak "Cannot change $what: this part of the node has already been written";
}

sub value { $_[0]{value} }
sub name { $_[0]{name} }
sub idx { $_[0]{idx} }
sub parent { $_[0]{parent} }
sub depth { $_[0]{depth} }
sub indent { $_[0]{indent} }

sub state {
   my $c= shift;
   return $c->{state} unless @_;
   $c->{state}= shift;
   return $c;
}
sub callback {
   my $c= shift;
   return $c->{cb} unless @_;
   my $cb= shift;
   !defined($cb) || ref($cb) eq 'CODE' or croak 'callback must be a code reference or undef';
   $c->_writable(1, 'callback');
   $c->{cb}= $cb;
   delete $c->{emit} if $c->{built};
   return $c;
}
sub leaves {
   my $c= shift;
   return $c->{leaves} unless @_;
   $c->{leaves}= (shift)? 1 : 0;
   return $c;
}
sub sortkeys {
   my $c= shift;
   return $c->{sortkeys} unless @_;
   my $spec= shift;
   my $sort= JGraft::JSON::_sorter($spec);
   $c->_writable(1, 'sortkeys');
   @{$c}{qw(sortkeys sort)}= ($spec, $sort);
   delete $c->{emit} if $c->{built};
   return $c;
}
sub layout {
   my $c= shift;
   if (@_) {
      my $layout= shift;
      !defined($layout) || $layout =~ /\A(?:fit|fill|stack|wrap)\z/ or croak "layout must be 'fit', 'fill', 'stack', 'wrap', or undef";
      $c->_writable(1, 'layout');
      $c->{layout}= $layout;
      delete $c->{auto};
      return $c;
   }
   return $c->{layout} if defined($c->{layout}) && ($c->{layout} ne 'wrap' || !$c->{_lay});
   # Kept apart from an assigned layout, which would discard retained whitespace.
   $c->{auto}= $c->{_lay}->($c) if !defined($c->{auto}) && $c->{_lay};
   return $c->{auto};
}
sub prefix {
   my $c= shift;
   if (@_) {
      $c->_writable(1, 'prefix');
      $c->{prefix}= _text(shift, 'prefix', $c->{indent});
      return $c;
   }
   $c->{prefix}= $c->{_pre}->($c) if !defined($c->{prefix}) && $c->{_pre};
   return $c->{prefix};
}
sub suffix {
   my $c= shift;
   if (@_) {
      $c->_writable(2, 'suffix');
      $c->{suffix}= _text(shift, 'suffix', $c->{last}? $c->{cindent} : $c->{indent});
      return $c;
   }
   $c->{suffix}= $c->{_suf}->($c) if !defined($c->{suffix}) && $c->{_suf};
   return $c->{suffix};
}
sub emit {
   my $c= shift;
   if (@_) {
      $c->_writable(1, 'emit');
      $c->{emit}= _text(shift, 'emit');
      $c->{built}= 0;
      return $c;
   }
   if (!defined($c->{emit}) && $c->{_emit}) {
      $c->{emit}= $c->{_emit}->($c);
      $c->{built}= 1;
   }
   return $c->{emit};
}
sub _text {
   my ($text, $what, $indent)= @_;
   !ref($text) or croak "$what must be a string or undef";
   # A trailing newline is completed with the line indent.
   $text .= $indent if defined($text) && defined($indent) && substr($text, -1) eq "\n";
   return $text;
}

my %PLACE= (before => 1, after => 1, open => 0, close => 0, key => 0, colon => 0);
sub comments {
   my $c= shift;
   my $place= @_? shift : 'before';
   exists $PLACE{$place} or croak "Unknown comment place '$place'";
   if (@_) {
      my $list= shift;
      $PLACE{$place} or croak "Comments in the '$place' place cannot be assigned";
      !defined($list) || ref($list) eq 'ARRAY' or croak 'comments must be an array reference or undef';
      for (@{$list || []}) {
         defined && !ref && m{\A(?://[^\r\n\x{2028}\x{2029}]*|/\*.*?\*/)\z}s
            or croak 'Each comment must be a complete // or /* */ comment';
      }
      $c->_writable($place eq 'before'? 1 : 2, "$place comments");
      $c->{$place}= $list && [@$list];
      return $c;
   }
   return @{$c->{$place}} if $c->{$place};
   my @gaps;
   if ($place eq 'open' || $place eq 'close') {
      my (undef, $outer)= JGraft::JSON::_layout_of($c->{value});
      @gaps= $outer? $outer->{$place} : ();
   }
   elsif (my $rec= $c->{rec}) {
      # Gap indexes as in JGraft::JSON::_Layout; objects lead with the key gap.
      my $object= defined $c->{name};
      @gaps= @{$rec}[$place eq 'before'? ($object? 3 : 0) : $place eq 'after'? (1, 2)
         : !$object? () : $place eq 'key'? 4 : $place eq 'colon'? 5 : ()];
   }
   my @out;
   for my $gap (grep ref, @gaps) {
      for (my $i= 1; $i < @$gap; $i += 2) {
         next unless defined $gap->[$i];
         (my $text= $gap->[$i]) =~ s/\A\0[ \t]*\0//;
         push @out, $text;
      }
   }
   return @out;
}

=head1 SYNOPSIS

  my $json= JGraft::JSON->new(pretty => 1, layout => sub {
     my $c= shift;                       # $_ is the node about to be written
     if (ref eq 'ARRAY' && @$_ > 3) {
        $c->layout('stack');             # one element per line
     }
     elsif (defined $c->idx && $c->idx == 0 && !ref) {
        $c->prefix('');                  # keep a leading scalar beside the bracket
     }
  });

=head1 DESCRIPTION

A cursor describes one node at the moment L<JGraft::JSON/encode> is about to
write it, and lets a C<layout> callback change how it is written. The encoder
calls the callback once for every node, in document order, with C<$_> aliased
to the node and the cursor as the only argument. C<$_> must not be modified.

A node is written as: L</prefix>, C<before> comments, the object key and colon
(for object members), the node's own text (L</emit>), a comma if another member
follows, C<after> comments, and L</suffix>. The prefix is the whitespace
separating a node from whatever precedes it. The suffix is normally empty, except
for the last member of a container, where it is the whitespace before the
closing bracket.

=head2 Lazy attributes

L</layout>, L</prefix>, L</suffix>, and L</emit> are unassigned until the
callback assigns them, meaning the encoder decides. Reading one that is not
assigned makes the encoder decide immediately, from the node's position and the
other attributes as they are at that moment, and keeps the result. Assigning
other attributes afterward does not revise a value already built: either assign
those first, or assign C<undef> to discard a built value and read it again. The
order of dependency is C<prefix>, then C<layout>, then C<emit>, then C<suffix>;
the default prefix of a member being packed onto a line also depends on the
width of its assigned C<emit> or C<layout>.

Reading an attribute of an ancestor returns what was decided for it. An
ancestor's C<emit> is unavailable (C<undef>) unless it was assigned.

Reading C<emit> writes the node's whole subtree, calling the callback for every
descendant. Discarding a built C<emit> and reading it again calls them again.

Decisions for containers are planned from the default one-line rendering of
their members, before the members' own callbacks run. Text assigned by those
callbacks is then written as given, and later layout follows from wherever it
leaves the line, without revising the decisions made for enclosing containers.

=head2 Write locking

When a node's callback returns, the encoder writes the node, and its C<prefix>,
C<layout>, C<emit>, C<sortkeys>, C<callback>, and C<before> comments can no longer
be assigned;
attempting to do so dies. Its C<suffix> and C<after> comments remain assignable
by the callbacks of its descendants, until its last descendant has been written.
L</state> and L</leaves> are never locked.

=attribute value

The node, as also found in C<$_>. Useful for the cursors of ancestors.

=attribute name

The key as a Perl string when the node is the value of an object member,
otherwise C<undef>.

=attribute idx

The zero-based position of the node within its parent array or object, or
C<undef> for the root.

=attribute parent

The cursor of the enclosing container, or C<undef> for the root.

=attribute depth

Zero for the root, increasing by one per container.

=attribute indent

The whitespace that begins a line holding this node when its container is
written on multiple lines.

=attribute state

  my $state= $c->state;
  $c->state($new);

An arbitrary value for the callback's own use. A node starts with the state its
parent had when the node was reached.

=attribute callback

  $c->callback(undef);          # no calls beneath this node
  $c->callback(\&for_literals); # a different callback beneath this node

The layout callback for the descendants of this node. A node starts with the
callback its parent had when the node was reached, the root with the encoder's
C<layout>; assigning it does not affect the call in progress. With C<undef>,
everything beneath this node is written without calls, as fast as encoding
without a callback (the attributes assigned to this node still apply).
Assigning it discards an C<emit> that was built by reading.

=attribute sortkeys

  $c->sortkeys(['id', 'name']);
  $c->sortkeys(sub { lc($a) cmp lc($b) });

The order of object members for this node and, by inheritance, its descendants,
as for L<JGraft::JSON/sortkeys>. A node starts with the value its parent had
when the node was reached, the root with the encoder's. C<undef> selects the
default order. Assigning it discards an C<emit> that was built by reading.

=attribute layout

  $c->layout('stack');

How a container's members are separated: C<'fit'> writes no line breaks of its
own (even when a member spans lines), C<'fill'> packs members onto lines within
the wrap width, and C<'stack'> starts a line for every member. C<'wrap'> chooses
C<'fit'> if the container fits on the rest of its line and C<'fill'> otherwise;
reading the attribute back gives the one chosen. (The encoder's own choice
differs in using C<'stack'> for a container holding containers of more than one
member, even when it would fit.) Assigning a layout to a container with retained
whitespace discards that whitespace. Unassigned, it reads as the encoder's
choice, or C<undef> for scalars, for which it is ignored.

=attribute prefix

=attribute suffix

  $c->prefix('');
  $c->suffix("\n");

Whitespace before and after the node, as described above. For a node with
retained whitespace, the retained text is what an unassigned attribute reads as.
A value ending in a newline is completed with the appropriate line indent. The
encoder writes these strings unchecked, so they should contain only whitespace
(or comments, when the output format permits them).

=attribute emit

  $c->emit('"replacement"');

The complete text of the node, replacing its value and, for a container, all of
its members, whose callbacks are then not called. The text is written unchecked.

Assigning the empty string omits the node: nothing is written for it, including
its prefix, comments, object key, and comma, and the separators of its
neighbors are adjusted as if the container did not have the member. The only
exception is that the suffix of a container's last member, being the whitespace
before the closing bracket, is still written when that member is omitted.
Omitting the root produces an empty document. (C<undef> does not omit; it
returns the attribute to its unassigned state.)

=method comments

  my @comments= $c->comments('before');
  $c->comments(after => ['// note']);

Read or assign the comments in a place around the node. Comments retained from
a decoded document can be read in every place: C<before> and C<after> the node,
after the C<open> bracket and before the C<close> bracket of a container, and
after the C<key> or C<colon> of an object member. The C<before> and C<after>
places can be assigned an arrayref of complete comments (C<undef> restores the
retained ones), which are written only if the codec has C<comments> enabled.

=method leaves

  $c->leaves(0);

Whether the callback is called for scalars beneath this node. Inherited by
descendants; the default is true.

=cut

1;
