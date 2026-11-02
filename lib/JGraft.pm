package JGraft;
# VERSION
# ABSTRACT: Cross-platform language for editing trees of data, which is itself a data tree

=head1 SYNOPSIS

  use JGraft qw( :constructors );
  my $graft= JGRAFT(
    MATCH(
      { title => ['STR'],
        content => ['STR'],
      },
      COPY(
        JOIN(' ', MAP(
          CASE('tyypo','typo',NODE),
          SPLIT(' ',NODE('title'))
        )),
        'title'
      ),
      ATSPLIT('content', CHARS("\n\t "),
        MATCH(
          ARRAY(0, SEQMIN(0,REP),
            "I", "always", "remember", "to", "run", "spellcheck"
          ),
          SPLICE(ADD(1,CAP(0,'ofs')), 0, "almost"),
        )
      ),
    )
  );
  # input data
  $graft->exec({
      title => "Title with a tyypo",
      content => "After editing I always remember to run spellcheck"
  });
  # output:
  #   { title => "Title with a typo",
  #     content => "After editing I almost always remember to run spellcheck"
  #   }
  
  jgparse(

=cut

use strict;
use warnings;
use Carp;
use Scalar::Util qw( blessed openhandle );
use overload ();

use Exporter 'import';
@JGraft::EXPORT_OK= qw( jgdiff jgpatch jgparse );

=head1 DESCRIPTION

This is the Perl 5 implementation of L<JGraft|https://github.com/nrdvana/JGraft>.  JGraft is a
portable lisp-like language for describing structural edits to trees of data, and is itself a
tree of data which can be encoded in JSON.  Its primary purpose is to serve as a "diff / patch"
equivalent for structured data.  For more information about the JGraft format itself, see the
L<specification/https://github.com/nrdvana/JGraft/SpecV1.md>.

=function jgdiff

  my $graft= jgdiff($from_data, $to_data, %options);
  # Shortcut for:
  #   my $d= JGraft::Diff->new(%options);
  #   $d->diff($from_data, $to_data) // die $d;

Produces a graft which can convert C<$data1> to C<$data2>.  Both values must be acyclic and
composed of values permitted by the default JGraft configuration.  If subtrees within the values
are used multiple times they are treated as if they were distinct clones.  i.e. this produces a
graft as if the inputs were pure trees, even if they were not.

=cut

sub jgdiff {
   my ($from_data, $to_data, %options)= @_;
   require JGraft::Diff;
   my $diff= JGraft::Diff->new(%options);
   $diff->diff($from_data, $to_data) || die $diff;
}

=function jgexec

  my $data_out= jgexec($graft, $data_in, %options);
  # Shortcut for:
  #   my $e= JGraft::Exec->new(%options, jgraft => $graft, input => $data_in);
  #   $e->apply // die $e;

Applies a graft to data, returning the result.  Dies on failure, throwing the L<JGraft::Exec>
object, which stringifies to a useful error message and contains other diagnostic attributes.
If C<$data1> is not a pure tree, the subtrees get implicitly cloned to ensure that the graft
applies correctly, but the original is not modified.  The result may contain references to
subtrees of the input, but the C<clone> option can ensure that the result is completely
disconnected from the original.

=cut

sub jgpatch {
   my ($graft, $data_in, %options)= @_;
   require JGraft::Patch;
   my $patch= JGraft::Patch->new(%options, jgraft => $graft);
   my @ret= $patch->patch($data_in);
   return @ret? $ret[0] : die $patch;
}

=function jgparse

  my $jgraft= jgparse($json);
  # Shortcut for:
  #   my $p= JGraft::Action->parse($json);

Takes either a string of JSON, or already-decoded JSON data (which must be an arrayref specifying
an action) and returns a JGraft action or expression object.  Grafts that are invalid per a
shallow static analysis (i.e. an action or expression constructor detects incorrect arguments)
die immediately.  This does not perform a deep static analysis of the expressions to determine
whether the graft is valid.  The input may also be a JGraft::Action object, in which case it
passes through unchanged.

=cut

sub jgparse {
   my $something= shift;
   return !defined $something? croak "Undefined input"
        : blessed($something) && $something->isa('JGraft::Action')? $something
        : JGraft::Action->parse($something);
}

require JGraft::Action;

=function coerce_json_to_data

This utility function takes a variety of inputs, returning json-like data as-is or extracting
JSON data from the thing in some manner.  Its behavior depends on the type of the argument:

=over

=item Plain Scalar

Plain scalars pass through unchanged.  While you might expect them to be treated as strings of
JSON and decoded, this would introduce ambiguity of whether the string was already the result of
decoding JSON (e.g. to be used as input for the graft operation) and hard-to-answer questions
about character encoding.

=item ARRAY-ref or HASH-ref

These are returned as-is, without verifying the internals are valid for JSON.

=item SCALAR-ref

Scalar-refs are assumed to refer to a string of UTF-8 bytes, and will be JSON-decoded as such.

=item File Handle

The handle (which must be open) is read from its current position until EOF.  If its PerlIO
layers indicate character decoding, the data read is interpreted as characters; otherwise it is
interpreted as UTF-8 bytes.

=item A known Path object

If the object is a known type of path object that could refer to a file, the file is opened in
C<:raw> mode (or dies) and assumed to contain UTF-8 bytes.

=item An object with TO_JSON

The object is serialized to JSON with "convert_blessed" enabled, then decoded into Perl data
with "allow_nonref" enabled (potentially returning a single scalar).

=back

This is used for most of the arguments of these utility functions to provide convenient DWIM
behavior.  If it doesn't work for your particular inputs, you always have the option of decoding
the JSON yourself.

=cut

my $_json;
sub _json {
   # choose which json decoder/encoder to use
   $_json ||= eval { require Cpanel::JSON::XS; 1 }? 'Cpanel::JSON::XS'
            : eval { require JSON::XS; 1 }? 'JSON::XS'
            : do { require JSON::PP; 'JSON::PP' };
}

# Path objects are recognized on a best-effort basis
our %path_classes= map { $_ => 1 } qw( Path::Class::File Path::Tiny Mojo::File IO::All );
sub coerce_json_to_data {
   my $in= shift;
   # Output that could result from decode_json is returned as-is.  Booleans are handled below.
   return $in if !ref $in || ref $in eq 'HASH' || ref $in eq 'ARRAY';
   # A scalar-ref is interpreted as UTF-8 bytes to decode.
   return _json->new->allow_nonref(1)->utf8->decode($$in)
     if ref $in eq 'SCALAR';
   # An already-open file handle means to read it from the current position.
   # If it has layers on it that are known to generate characters rather than bytes,
   # use the characters, else assume we need to decode UTF-8.
   my ($coder, $in_handle)= (_json->new->allow_nonref(1));
   if (openhandle($in)) {
      $in_handle= $in;
      # assume reading decoded characters if encoding is set
      $coder->utf8 unless grep /^(?:encoding\(|utf8\z)/i, PerlIO::get_layers($in_handle);
   }
   # If the object clearly represents a file path, open that path.
   # Use raw mode and assume the file contains UTF-8.  If it doesn't, the user should instead
   # pass a file handle with the appropriate layer set.
   elsif (blessed($in) && (
      $path_classes{blessed($in)}
      || (grep $in->isa($_), keys %path_classes)
   )) {
      open $in_handle, '<:raw', "$in" or croak "open($in): $!";
      $coder->utf8;
   }
   # If the object can be serialized to JSON, try that.
   # This also catches cases of JSON boolean objects.
   elsif (blessed($in)) {
      my $clone;
      eval { $clone= $coder->decode($coder->convert_blessed->encode($in)); 1 }
         or croak "Failed to convert ".ref($in)." to JSON: $@";
      return $clone;
   }
   else {
      croak "Can't convert ".ref($in)." to JSON data";
   }
   my $buf= '';
   do {
     my $n= read($in_handle, $buf, 65536, length($buf));
     defined $n or croak "Error reading JSON input: $!";
   } while ($n);
   return $coder->decode($buf);
}

1;
