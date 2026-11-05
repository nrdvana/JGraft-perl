package JGraft::_JSON;
# VERSION
# ABSTRACT: Compatibility transport for native conformance values
use strict;
use warnings;
no warnings 'recursion';
use JGraft::JSON ();

# Keep the existing fixture/formatter interface while sharing one strict parser.
# Normal execution still uses the caller's data and does not pay for this codec.
sub decode {
   my ($text,%options)=@_;
   $_ eq 'preserve_numbers' or die "Unknown JSON decoder option '$_'\n" for keys %options;
   my $json=JGraft::JSON->new(utf8=>!utf8::is_utf8($text));
   return _native($json->decode($text),$options{preserve_numbers});
}
sub _native {
   my ($v,$preserve)=@_;
   if (ref($v) eq 'JGraft::JSON::Number') {
      my $token=$v->token;
      return $preserve?bless(\$token,'JGraft::_JSON::Number'):0+$token;
   }
   return $v->value if ref($v) eq 'JGraft::JSON::String';
   return [map _native($_,$preserve),@$v] if ref($v) eq 'ARRAY';
   return {map +($_=>_native($v->{$_},$preserve)),keys %$v} if ref($v) eq 'HASH';
   return $v;
}

=head1 DESCRIPTION

Private compatibility adapter around L<JGraft::JSON> for conformance fixtures and
older formatter callers that require native scalar values and untied hashes.
New applications should use the public codec directly.

=function decode

Decode JSON characters or UTF-8 bytes. With C<< preserve_numbers => 1 >>, numeric
tokens become private scalar-reference objects carrying their original spelling.
Otherwise numeric tokens become native Perl numbers. Object duplicates collapse
to their final value, while surrogate decoding follows the public codec.

=cut

1;
