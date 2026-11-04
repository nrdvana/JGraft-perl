package JGraft::_JSON;
# VERSION
# ABSTRACT: Decode JSON while preserving surrogate and numeric tokens
use strict;
use warnings;

sub decode {
   my ($text,%options)=@_;
   $_ eq 'preserve_numbers' or die "Unknown JSON decoder option '$_'\n" for keys %options;
   require JSON::PP;
   require utf8;
   utf8::is_utf8($text) || utf8::decode($text) or die 'Invalid UTF-8 in JSON';
   my $offset=0;
   my $value=_value(\$text,\$offset,$options{preserve_numbers});
   _space(\$text,\$offset);
   $offset==length($text) or die 'Unexpected trailing data in JSON';
   return $value;
}
sub _space {
   my ($text,$offset)=@_;
   pos($$text)=$$offset;
   $$text =~ /\G[ \t\r\n]*/gc;
   $$offset=pos($$text);
}
sub _value {
   no warnings 'utf8';
   my ($text,$offset,$preserve)=@_;
   _space($text,$offset);
   my $first=substr($$text,$$offset,1);
   if ($first eq '{' || $first eq '[') {
      ++$$offset;
      my ($object,$array)=({},[]);
      my $close=$first eq '{'? '}' : ']';
      _space($text,$offset);
      unless (substr($$text,$$offset,1) eq $close) {
         while (1) {
            my $key;
            if ($first eq '{') {
               substr($$text,$$offset,1) eq '"' or die 'Expected JSON object key';
               $key=_value($text,$offset,$preserve);
               _space($text,$offset);
               substr($$text,$$offset,1) eq ':' or die 'Expected JSON colon';
               ++$$offset;
            }
            my $value=_value($text,$offset,$preserve);
            if ($first eq '{') { $object->{$key}=$value }
            else { push @$array,$value }
            _space($text,$offset);
            last unless substr($$text,$$offset,1) eq ',';
            ++$$offset;
            _space($text,$offset);
         }
      }
      substr($$text,$$offset,1) eq $close or die 'Expected JSON closing delimiter';
      ++$$offset;
      return $first eq '{'? $object : $array;
   }
   pos($$text)=$$offset;
   if ($$text =~ /\G"((?:[^"\\\x00-\x1f]|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*)"/gc) {
      $$offset=pos($$text);
      my $value=$1;
      $value =~ s{\\(?:u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][cdefCDEF][0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|(["\\/bfnrt]))}
         {_escape($1,$2,$3,$4)}eg;
      return $value;
   }
   if ($$text =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/gc) {
      $$offset=pos($$text);
      my $token=$1;
      return $preserve? bless(\$token,'JGraft::_JSON::Number') : 0+$token;
   }
   if ($$text =~ /\G(true|false|null)/gc) {
      $$offset=pos($$text);
      return $1 eq 'true'? JSON::PP::true() : $1 eq 'false'? JSON::PP::false() : undef;
   }
   die 'Expected JSON value';
}
sub _escape {
   no warnings 'utf8';
   my ($hi,$lo,$cp,$simple)=@_;
   return chr(0x10000+((hex($hi)-0xd800)<<10)+hex($lo)-0xdc00) if defined $hi;
   return chr(hex($cp)) if defined $cp;
   my %escapes=('"'=>'"','\\'=>'\\','/'=>'/',b=>"\x08",f=>"\x0c",n=>"\n",r=>"\r",t=>"\t");
   return $escapes{$simple};
}

=head1 DESCRIPTION

Private JSON decoder shared by the formatter and conformance reader. Lone
surrogates remain codepoints; only adjacent escaped UTF-16 pairs are combined.

=function decode

Decode JSON characters or UTF-8 bytes. With C<< preserve_numbers => 1 >>, numeric
tokens become private scalar-reference objects carrying their original spelling,
so formatting cannot round large integers or overflow/underflow exponents.
Otherwise numeric tokens become native Perl numbers.

=cut

1;
