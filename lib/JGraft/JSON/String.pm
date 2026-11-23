package JGraft::JSON::String;
# VERSION
# ABSTRACT: Immutable decoded string with its original JSON or JSON5 spelling
use strict;
use warnings;
use overload '""'=>sub { $_[0][0] }, 'bool'=>sub { length($_[0][0]) && $_[0][0] ne '0' }, fallback=>1;

# [value, token, ascii, flags, document layout]. Flags: 1 = JSON5-only
# spelling, 2 = identifier (object key) without quotes.
# Only the decoder constructs these, after validating the complete string token.
sub _new { my $class=shift; bless [@_],$class }
sub value { $_[0][0] }
sub token { $_[0][1] }
sub is_json { ($_[0][3] || 0) & 1? 0 : 1 }
sub json_token {
   my $s=shift;
   return $s->[1] if $s->is_json;
   require JGraft::JSON;
   return JGraft::JSON->new(ascii=>$s->[2])->_quote($s->[0]);
}

=head1 DESCRIPTION

A decoded string whose original spelling differs from the encoder's normal
spelling, or a root string retaining document whitespace or comments. String
operations use the decoded value. L<JGraft::JSON> reuses its validated original
token when encoded with the same C<ascii> setting, and for JSON5 spellings only
when encoding JSON5 (identifier spellings only as object keys). String
operations produce ordinary strings, discarding this spelling metadata.
Instances are immutable by convention; there is no public raw-token constructor.

=method value

Return the decoded characters.

=method token

Return the original string token, including quotes, or an identifier key.

=method is_json

True when the original token is valid JSON.

=method json_token

Return the original token when valid JSON, or a JSON spelling of the value.

=cut

1;
