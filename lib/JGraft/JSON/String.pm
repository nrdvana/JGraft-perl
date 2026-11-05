package JGraft::JSON::String;
# VERSION
# ABSTRACT: Immutable decoded string with its original JSON spelling
use strict;
use warnings;
use overload '""'=>sub { $_[0][0] }, 'bool'=>sub { length($_[0][0]) && $_[0][0] ne '0' }, fallback=>1;

# Only the decoder constructs these, after validating the complete string token.
sub _new { my $class=shift; bless [@_],$class }
sub value { $_[0][0] }
sub token { $_[0][1] }

=head1 DESCRIPTION

A decoded string whose original escape spelling differs from the encoder's
normal spelling. String operations use the decoded value. L<JGraft::JSON>
reuses its validated original token when encoded with the same C<ascii> setting.
String operations produce ordinary strings, discarding this spelling metadata.
Instances are immutable by convention; there is no public raw-token constructor.

=method value

Return the decoded characters.

=method token

Return the original JSON string token, including quotes.

=cut

1;
