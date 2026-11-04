package JGraft;
# VERSION
# ABSTRACT: Cross-platform language for editing trees of data, which is itself a data tree

=head1 SYNOPSIS

  use JGraft qw( :constructors );
  my $graft= JGRAFT(
    MATCH(
      { title => STR,
        content => STR,
      },
      COPY(
        JOIN(' ', MAP(
          CASE('tyypo','typo',NODE),
          SPLIT(' ',NODE('title'))
        )),
        'title'
      ),
      ATSPLIT('content', { sep => CHARS("\n\t "), default => ' ' },
        MATCH(
          ARRAY(0, SEQMIN(0,REP),
            "I", "always", "remember", "to", "run", "spellcheck"
          ),
          SPLICE(NODE(ADD(1,CAP(0,'ofs'))), 0, "almost"),
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
  
=cut

use strict;
use warnings;
use Carp;
use Scalar::Util qw( blessed openhandle );
use overload ();

use Exporter 'import';
@JGraft::EXPORT_OK= qw( jgdiff jgexec jgparse jgformat json_data );

=head1 DESCRIPTION

This is the Perl 5 implementation of L<JGraft|https://github.com/nrdvana/JGraft>.  JGraft is a
portable lisp-like language for describing structural edits to trees of data, and is itself a
tree of data which can be encoded in JSON.  Its primary purpose is to serve as a "diff / patch"
equivalent for structured data.  For more information about the JGraft format itself, see the
L<specification|https://github.com/nrdvana/JGraft/SpecV1.md>.

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

sub jgexec {
   my ($graft, $data_in, %options)= @_;
   require JGraft::Exec;
   my $exec= JGraft::Exec->new(%options, jgraft => $graft);
   my @ret= $exec->apply($data_in);
   return @ret? $ret[0] : die $exec;
}

=function jgparse

  $jgraft= jgparse($json_string);
  $jgraft= jgparse(path("./foo.jg"));
  $jgraft= jgparse(\*HANDLE);
  $jgraft= jgparse(\@data);
  $jgraft= jgparse(\$json_utf8);

This function extracts JSON data from the argument according to its type, then passes it to
L<JGraft::Action/new_from_json_data>.  The argument can be anything supported by the
L</json_data> function, and additionally can be a string of JSON text.  If the graft is clearly
invalid (as detected by the constructors of the actions and expressions) this will die with
an C<INVALID_GRAFT> error.

Note that the C<$json_string> form suffers from the usual problem of requiring you to have
pre-decoded your input into "characters" (not bytes) and it is easy to pass UTF-8 bytes by
accident.  This function warns if it encounters a string that also happens to be a valid
UTF-8 sequence of bytes.  If you know that your input is UTF-8 bytes, pass it as a scalar-ref.
You can disable the warning with C<< $JGraft::warn_utf8_scalar=0 >>.

=cut

our $warn_utf8_scalar= 1;
sub jgparse {
   my $something= shift;
   defined $something or croak "Undefined input";
   unless (ref $something) {
      if ($warn_utf8_scalar && $something =~ /[^\x00-\x7F]/ && utf8::decode(my $tmp= $something)) {
         carp "Scalar will be parsed as characters, but looks like UTF-8 bytes.  "
            . "Pass UTF-8 buffers as a scalar-ref.";
         $warn_utf8_scalar= 0;
      }
      return JGraft::Action->new_from_json_data(_json()->new->allow_nonref(0)->decode($something));
   }
   return $something if blessed($something) && $something->isa('JGraft::Action');
   return JGraft::Action->new_from_json_data(json_data($something));
}

require JGraft::Action;

=function jgformat

  my $text= jgformat($json_data, indent => 2, wrap => 79);

Format decoded JSON data, or an action/expression object. Embedded C<["JGRAFT", ...]>
arrays are parsed and use directive formatting when valid; invalid grafts remain
ordinary JSON. Other containers stay inline unless a child has multiple members
or requires multiple lines, in which case each member gets its own line. Long
flat containers wrap at member boundaries. Options match L<JGraft::Action/format>.

Strings are literal JSON string values, not JSON text to decode. For UTF-8 files,
L<jg-format> also preserves original numeric tokens and lone surrogate escapes.

=cut

sub jgformat {
   require JGraft::_Format;
   return JGraft::_Format->format_json(@_);
}

=function json_data

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
sub json_data {
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
   my $n;
   do {
      $n= read($in_handle, $buf, 65536, length($buf));
      defined $n or croak "Error reading JSON input: $!";
   } while ($n);
   return $coder->decode($buf);
}

=function C<:constructors>

The C<:constructors> export tag provides uppercase constructor functions matching the name of
every action and expression.  The arguments for each are identical to their JSON-encoded form,
though some constructor functions have additional special cases for their arguments, as noted
below.  All arguments are interpreted as perl data, not JGraft JSON-encoded expressions.
In other words, an array is an array, not an expression.  To construct an action or expression
from JSON-encoded data, use the L<JGraft::Action/new_from_json_data> or
L<JGraft::Expr/new_from_json_data> constructors.

=head4 Actions

  JGRAFT(\%metadata, @actions)
  JGRAFT(@actions)                  # implied { v => 1 } for %meta
  RAISE($level, $message)
  RAISE($level, $message, $data=undef)
  AT($path, @actions)
  ATSPLIT($path, $split_spec, @actions)
  MATCH($match_spec, @actions)
  IF(@branch_pairs, $else_action)
  COPY(@val_dst_pairs)
  MOVE(@src_dst_pairs)
  SPLICE($elem_path, $del_count, @replacements)

=head4 Ref Expressions

=head4 Match Expressions

=head4 Function Expressions

=for Pod::Coverage [A-Z]+

=cut

# Export each Action and Expression as a function which takes the same arguments
# as the JSON notation.  This is done by simply passing the argument list as an
# arrayref to the constructor.
our %EXPORT_TAGS;
{
   no strict 'refs';
   my @constructors;
   for my $registry ('JGraft::Action', 'JGraft::Expr') {
      my $names= \%{$registry.'::by_name'};
      for my $name (sort keys %$names) {
         my $class= $registry->get_class($name);
         *{__PACKAGE__.'::'.$name}= $name eq 'JGRAFT'? sub {
            my @args= @_;
            unshift @args, {v=>1} unless @args && ref $args[0] eq 'HASH';
            $class->new(\@args);
         } : sub { $class->new([@_]) };
         push @constructors, $name;
      }
   }
   push @JGraft::EXPORT_OK, @constructors;
   $EXPORT_TAGS{constructors}= \@constructors;
}

1;
