package JGraft::JSON;
# VERSION
# ABSTRACT: Strict JSON with exact numbers, escape spelling, and duplicate members
use strict;
use warnings;
no warnings 'recursion';
use Carp 'croak';
use Scalar::Util qw(blessed refaddr);
use JSON::PP ();
use JGraft::Util qw(:types type_mask is_finite);
use JGraft::JSON::Number;
use JGraft::JSON::String;
use JGraft::JSON::Object;
sub new {
   my ($class,%options)=@_;
   my %defaults=(ascii=>0,utf8=>0,max_depth=>256,max_size=>0,
      max_number_digits=>10000,number_overflow=>'reject');
   exists $defaults{$_} or croak "Unknown JSON option '$_'" for keys %options;
   my $s=bless {%defaults,%options},$class;
   for my $key (qw(max_depth max_size max_number_digits)) {
      defined($s->{$key}) && !ref($s->{$key}) && $s->{$key} =~ /\A[0-9]+\z/
         or croak "$key must be a nonnegative integer";
   }
   defined($s->{number_overflow}) && $s->{number_overflow} =~ /\A(?:reject|native)\z/ or croak 'number_overflow must be reject or native';
   return $s;
}
sub ascii { $_[0]{ascii}=@_>1?!!$_[1]:1; $_[0] }
sub utf8 { $_[0]{utf8}=@_>1?!!$_[1]:1; $_[0] }
sub decode {
   my ($s,$text)=@_;
   defined($text) && !ref($text) or croak 'Expected JSON text';
   $s->{max_size} && length($text)>$s->{max_size} and croak 'JSON exceeds max_size';
   if ($s->{utf8}) {
      utf8::is_utf8($text) && $text =~ /[^\x00-\xff]/ and croak 'Expected UTF-8 bytes';
      utf8::downgrade($text,1) or croak 'Expected UTF-8 bytes' if utf8::is_utf8($text);
      # utf8::decode also accepts Perl's extended UTF-8 (including surrogates)
      # on some versions. JSON bytes must use the Unicode UTF-8 encoding.
      pos($text)=0;
      while ($text =~ /\G(?>(?:[\x00-\x7f]+|[\xc2-\xdf][\x80-\xbf]
         |\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee-\xef][\x80-\xbf]{2}
         |\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}
         |[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2}){1,128})/gcx) { }
      (pos($text)||0)==length($text) or croak 'Invalid UTF-8 in JSON';
      utf8::decode($text) or croak 'Invalid UTF-8 in JSON';
   }
   my $offset=0;
   my $out=$s->_value(\$text,\$offset,1);
   _space(\$text,\$offset);
   $offset==length($text) or croak "Unexpected trailing data at character $offset";
   return $out;
}
sub _space {
   my ($text,$offset)=@_;
   pos($$text)=$$offset;
   $$text =~ /\G[ \t\r\n]*/gc;
   $$offset=pos($$text);
}
sub _depth {
   my ($s,$depth)=@_;
   $s->{max_depth} && $depth>$s->{max_depth} and croak 'JSON exceeds max_depth';
}
sub _value {
   my ($s,$text,$offset,$depth)=@_;
   _space($text,$offset);
   my $first=substr($$text,$$offset,1);
   return $s->_string($text,$offset) if $first eq '"';
   if ($first eq '{' || $first eq '[') {
      $s->_depth($depth);
      ++$$offset;
      my (@array,%object);
      my $tie=$first eq '{'? tie(%object,'JGraft::JSON::Object') : undef;
      my $close=$first eq '{'?'}':']';
      _space($text,$offset);
      unless (substr($$text,$$offset,1) eq $close) {
         while (1) {
            my $key;
            if ($tie) {
               $key=$s->_string($text,$offset);
               _space($text,$offset);
               substr($$text,$$offset,1) eq ':' or croak "Expected JSON colon at character $$offset";
               ++$$offset;
            }
            my $v=$s->_value($text,$offset,$depth+1);
            if ($tie) { $tie->_append("$key",$key,$v) }
            else { push @array,$v }
            _space($text,$offset);
            last unless substr($$text,$$offset,1) eq ',';
            ++$$offset;
            _space($text,$offset);
         }
      }
      substr($$text,$$offset,1) eq $close or croak "Expected JSON closing delimiter at character $$offset";
      ++$$offset;
      return $tie?\%object:\@array;
   }
   pos($$text)=$$offset;
   if ($$text =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/gc) {
      $$offset=pos($$text);
      return JGraft::JSON::Number->new($1,map +($_=>$s->{$_}),qw(max_number_digits number_overflow));
   }
   if ($$text =~ /\G(true|false|null)/gc) {
      $$offset=pos($$text);
      return $1 eq 'true'?JSON::PP::true():$1 eq 'false'?JSON::PP::false():undef;
   }
   croak "Expected JSON value at character $$offset";
}
sub _string {
   no warnings 'utf8';
   my ($s,$text,$offset)=@_;
   my $start=$$offset;
   substr($$text,$start,1) eq '"' or croak "Expected JSON string at character $start";
   pos($$text)=$start+1;
   # Bounded repeats avoid the recursive regex engine's stack limits on old
   # interpreters, for both long plain strings and long runs of escapes.
   while ($$text =~ /\G(?>(?:[^"\\\x00-\x1f]+|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4})){1,128})/gc) { }
   my $end=pos($$text);
   substr($$text,$end,1) eq '"' or croak "Expected JSON string at character $start";
   $$offset=$end+1;
   my ($token,$value)=(substr($$text,$start,$end+1-$start),substr($$text,$start+1,$end-1-$start));
   $value =~ s{\\(?:u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][cdefCDEF][0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|(["\\/bfnrt]))}
      {_escape($1,$2,$3,$4)}eg;
   $value =~ /[^\x{0}-\x{10ffff}]/ and croak 'Codepoint exceeds Unicode maximum';
   return $value if $token =~ /[\x{d800}-\x{dfff}]/;
   return $token eq $s->_quote($value)?$value:JGraft::JSON::String->_new($value,$token,$s->{ascii});
}
sub _escape {
   no warnings 'utf8';
   my ($hi,$lo,$cp,$simple)=@_;
   return chr(0x10000+((hex($hi)-0xd800)<<10)+hex($lo)-0xdc00) if defined $hi;
   return chr(hex($cp)) if defined $cp;
   my %escapes=('"'=>'"','\\'=>'\\','/'=>'/',b=>"\x08",f=>"\x0c",n=>"\n",r=>"\r",t=>"\x09");
   return $escapes{$simple};
}
sub _quote {
   no warnings 'utf8';
   my ($s,$v)=@_;
   my %simple=(8=>'\\b',9=>'\\t',10=>'\\n',12=>'\\f',13=>'\\r',34=>'\\"',92=>'\\\\');
   my $out='"';
   for my $ch (split //,"$v") {
      my $cp=ord($ch);
      $cp<=0x10ffff or croak 'Codepoint exceeds Unicode maximum';
      if (exists $simple{$cp}) { $out.=$simple{$cp} }
      elsif ($cp<32 || ($cp>=0xd800 && $cp<=0xdfff) || ($s->{ascii} && $cp>127)) {
         $out.=$cp<=0xffff?sprintf('\\u%04x',$cp)
            :sprintf('\\u%04x\\u%04x',0xd800+(($cp-0x10000)>>10),0xdc00+(($cp-0x10000)&1023));
      }
      else { $out.=$ch }
   }
   return $out.'"';
}
sub encode {
   my ($s,$v)=@_;
   my $text=$s->_encode($v,1,{});
   if ($s->{utf8}) { utf8::encode($text) }
   $s->{max_size} && length($text)>$s->{max_size} and croak 'JSON exceeds max_size';
   return $text;
}
sub _encode {
   my ($s,$v,$depth,$active)=@_;
   return 'null' unless defined $v;
   return $v?'true':'false' if JSON::PP::is_bool($v);
   if (blessed($v)) {
      return $v->token if $v->isa('JGraft::JSON::Number');
      return $v->[2]==$s->{ascii}?$v->token:$s->_quote($v->value) if $v->isa('JGraft::JSON::String');
      return JGraft::Util::to_decimal_string($v,$s->{max_number_digits}) if JGraft::Util::is_number_object($v);
      croak 'Unsupported JSON object '.ref($v);
   }
   my $type=type_mask($v);
   return $s->_quote($v) if $type==TYPE_STRING;
   if ($type==TYPE_NUMBER) {
      is_finite($v) or croak 'Cannot encode a non-finite JSON number';
      return JSON::PP->new->allow_nonref->encode($v);
   }
   $type==TYPE_ARRAY || $type==TYPE_OBJECT or croak 'Unsupported JSON reference '.ref($v);
   $s->_depth($depth);
   my $id=refaddr($v);
   $active->{$id} and croak 'Cannot encode cyclic JSON data';
   local $active->{$id}=1;
   if ($type==TYPE_ARRAY) {
      my @out;
      for my $i (0..$#$v) {
         exists $v->[$i] or croak 'Cannot encode a sparse JSON array';
         push @out,$s->_encode($v->[$i],$depth+1,$active);
      }
      return '['.join(',',@out).']';
   }
   my $tie=tied %$v;
   my @out;
   if ($tie && $tie->isa('JGraft::JSON::Object')) {
      for (my $i=$tie->{head};defined $i;$i=$tie->{seq}[$i+1]) {
         $JGraft::JSON::Object::EXEC->_tick(1) if $JGraft::JSON::Object::EXEC;
         push @out,$s->_encode($tie->{tokens}[$i],$depth+1,$active).':'.$s->_encode($tie->{tokens}[$i+1],$depth+1,$active);
      }
   }
   else {
      push @out,$s->_quote($_).':'.$s->_encode($v->{$_},$depth+1,$active) for sort keys %$v;
   }
   return '{'.join(',',@out).'}';
}

=head1 SYNOPSIS

  my $json= JGraft::JSON->new(utf8 => 1);
  my $data= $json->decode($bytes);
  my $edited= JGraft::jgexec($graft, $data);
  my $bytes_out= $json->encode($edited);

=head1 DESCRIPTION

A strict JSON codec for applications needing exact decimal numbers and retention
of untouched string escape spellings, member order, and duplicate object keys.
Whitespace is normalized away. Comments, bare keys, trailing commas, non-finite
numbers, and nonstandard JSON extensions are rejected. Top-level scalars are
allowed. Only adjacent escaped UTF-16 surrogate pairs are combined; unpaired
surrogates remain separate codepoints and are always escaped on output.

Numbers are L<JGraft::JSON::Number> objects retaining their original token and
converting lazily to Math::BigRat. Strings become ordinary scalars unless their
original spelling requires a L<JGraft::JSON::String> wrapper. These values can be
used directly with JGraft. Other JSON libraries need not understand them.

Objects are ordinary hashrefs tied to L<JGraft::JSON::Object>. Reading a duplicated
key returns its last value; keys/values/each expose each key once, in the order
of its final occurrence. Untouched
duplicates retain their original positions and values on serialization. STORE
collapses that key's occurrences into one member at its final original position;
DELETE removes them all. Nested edits count as writing the parent key during
JGraft's copy-on-write. No JSON whitespace or layout metadata is maintained.

Math::BigInt, Math::BigFloat, and Math::BigRat can also be encoded. Their values
are emitted exactly; a rational without a terminating decimal expansion is an
error. Callers must explicitly round such values before serialization.

=constructor new

Options are C<ascii> (escape non-ASCII output; default false), C<utf8> (accept and
produce UTF-8 bytes instead of characters; default false), C<max_depth> (256),
C<max_size> (0, unlimited input/output length), C<max_number_digits> (10000), and
C<number_overflow> (C<reject> or C<native>, default C<reject>). Zero disables a
size/depth/digit bound. Number limits apply to numeric conversion and fresh big
number emission; original numeric tokens can always round-trip without expansion.
The native overflow policy permits approximate arithmetic, not loss of the
retained token. Escapes are preserved when using the same C<ascii> configuration;
changing that configuration re-encodes wrapped strings normally.

=method decode

Decode one complete JSON document, dying on invalid input or a configured limit.
The input scalar is never modified.

=method encode

Encode an acyclic JSON tree without optional whitespace. Untied hashes use sorted
keys; tied decoded objects preserve source order and untouched duplicates. Dies
on unsupported objects, sparse arrays, or non-finite values.

=method ascii

=method utf8

Set the corresponding flag (true when called without an argument), returning the
codec for chaining. These methods do not change already decoded values.

=cut

1;
