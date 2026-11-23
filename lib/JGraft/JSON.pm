package JGraft::JSON;
# VERSION
# ABSTRACT: JSON and JSON5 with exact numbers, original spellings, layout, and comments
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
use JGraft::JSON::Array;
use JGraft::JSON::_Layout qw(V_PRE M_PRE POST K_PRE C_PRE C_POST final_ws has_comments
   container_layout document_layout arrange);

my @FLAGS=qw(ascii utf8 json5 comments preserve_whitespace pretty);
my $ID_START=qr/[\$_\p{L}\p{Nl}]/;
my $ID_PART=qr/[\$_\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}\x{200C}\x{200D}]/;
my $EMPTY=[('') x 6];

sub new {
   my ($class,%options)=@_;
   my %defaults=((map +($_=>0),@FLAGS),indent_length=>2,wrap=>79,max_depth=>256,max_size=>0,
      max_number_digits=>10000,number_overflow=>'reject');
   exists $defaults{$_} or croak "Unknown JSON option '$_'" for keys %options;
   my $self=bless {%defaults,%options},$class;
   for my $key (qw(max_depth max_size max_number_digits indent_length wrap)) {
      defined($self->{$key}) && !ref($self->{$key}) && $self->{$key} =~ /\A[0-9]+\z/
         or croak "$key must be a nonnegative integer";
   }
   defined($self->{number_overflow}) && $self->{number_overflow} =~ /\A(?:reject|native)\z/ or croak 'number_overflow must be reject or native';
   return $self;
}
for my $flag (@FLAGS) {
   no strict 'refs';
   *$flag=sub { $_[0]{$flag}=@_>1?!!$_[1]:1; $_[0] };
}
for my $key (qw(indent_length wrap)) {
   no strict 'refs';
   *$key=sub {
      my ($self,$n)=@_;
      defined($n) && !ref($n) && $n =~ /\A[0-9]+\z/ or croak "$key must be a nonnegative integer";
      $self->{$key}=$n;
      return $self;
   };
}

# ---- Decoding ----

# Decoding works on the UTF-8 encoding of the text, so that every position is
# a byte offset: match offsets and pos on a character string cost a scan of
# the string on older Perls, and @- and @+ on every Perl. ASCII syntax is
# matched directly, since no byte of a multi-byte sequence is ASCII; strings
# containing other bytes are decoded as they are extracted. A document retained
# for its whitespace or comments keeps the same bytes and offsets (see
# JGraft::JSON::_Layout).
sub decode {
   my ($self, $text)= @_;
   defined($text) && !ref($text) or croak 'Expected JSON text';
   $self->{max_size} && length($text) > $self->{max_size} and croak 'JSON exceeds max_size';
   if ($self->{utf8}) {
      utf8::is_utf8($text) && $text =~ /[^\x00-\xff]/ and croak 'Expected UTF-8 bytes';
      utf8::downgrade($text, 1) or croak 'Expected UTF-8 bytes' if utf8::is_utf8($text);
      # JSON bytes must use the Unicode UTF-8 encoding, without the surrogates
      # and extended sequences Perl's own decoder accepts.
      pos($text)= 0;
      while ($text =~ /\G(?>(?:[\x00-\x7f]+|[\xc2-\xdf][\x80-\xbf]
         |\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee-\xef][\x80-\xbf]{2}
         |\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}
         |[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2}){1,128})/gcx) { }
      (pos($text) || 0) == length($text) or croak 'Invalid UTF-8 in JSON';
   }
   else { utf8::encode($text) }
   # Matching runs on this function's copy, keeping pos magic off the document.
   my $doc;
   if ($self->{preserve_whitespace} || $self->{comments}) {
      $doc= {
         text => $text, t => [],
         cw => $self->{preserve_whitespace}? 1 : 0,
         cc => $self->{comments}? 1 : 0,
         cm => $self->{json5} || $self->{comments}? 1 : 0,
         j5 => $self->{json5}? 1 : 0,
         ascii => $self->{ascii}? 1 : 0,
      };
      $doc->{id}= refaddr(\$doc->{text});
   }
   my ($out, $first, $last)= $self->_parse(\$text, $doc);
   return $doc? $self->_attach_document($doc, $out, $first, $last) : $out;
}
sub _depth {
   my ($self, $depth)= @_;
   $self->{max_depth} && $depth > $self->{max_depth} and croak 'JSON exceeds max_depth';
}
# Errors report character offsets.
sub _fail {
   my ($text, $message, $at)= @_;
   croak "$message at character ".($at-(substr($$text, 0, $at) =~ tr/\x80-\xbf//));
}

# The decoder is a loop around one static pattern, resumed with \G. Each match
# is one token, optionally preceded by a comma and by a plain key and colon, so
# that an ordinary member or element is a single match. The highest capture
# group that matched ($#-) names the token. Tokens outside that prefix
# (after a comment, say) arrive on their own, and $st tracks what may follow.
#   prefix: 1 comma   2 plain "key" body   3 identifier key   4 colon   5 token start
#   values: 6 plain "string" body   7 number   8 true/false/null   9 opening quote
#           10 [ or {   11 ] or }
#   others: 12 comma   13 colon   14 comment opener
#   JSON5:  15 single quote   16 number   17 whitespace   18 identifier start
# Group numbers follow the order of the alternatives, commonest first, and the
# dispatch below halves that range rather than testing each number in turn.
sub _parse {
   my ($self, $text, $doc)= @_;
   my ($j5, $ascii, $maxdepth, $maxn, $ovf)
      = @{$self}{qw(json5 ascii max_depth max_number_digits number_overflow)};
   my $cm= $j5 || $self->{comments};
   # Whether any string, or text taken from the document, can need decoding,
   # and whether such strings must instead keep an escaped spelling.
   my $wide= $$text =~ tr/\x80-\xff//;
   $doc->{wide}= 1 if $doc && $wide;
   my $esc= $wide && $ascii;
   my ($t, $id)= $doc? ($doc->{t}, $doc->{id}) : ();
   # The container being filled: its reference, where its members go (an items
   # array or an object tie), its member count, and its opening token. The
   # stack holds the same for enclosing containers, with the pending key.
   my (@stack, $ref, $into, $is_obj, $open, $root, $first, $key, $done, $at);
   my ($n, $st)= (0, 0);   # st: 0 member start  1 after value  2 after key  3 after colon
   pos($$text)= 0;
   while ($$text =~ m{
      \G (?> [\ \t\r\n]* )

      # Prefix: a comma
      (?: (,) (?> [\ \t\r\n]* ) )?

      # Prefix: a key and its colon
      (?:
         (?:
            # plain string, as below
            " ( (?> (?> [\x20\x21\x23-\x5b\x5d-\xec\xee-\xf3]* )
                    (?> (?: (?: \xed[\x80-\x9f] | \xf4[\x80-\x8f] )
                            (?> [\x20\x21\x23-\x5b\x5d-\xec\xee-\xf3]* ) ){0,64} ) ) ) "
         |
            # JSON5 ASCII identifier
            ( [\$_A-Za-z] (?> [\$_A-Za-z0-9]* ) )
         )
         (?> [\ \t\r\n]* ) (:) (?> [\ \t\r\n]* )
      )?

      # Token
      ()
      (?:
         # plain string: no quote, backslash, or control, and no encoding of a
         # surrogate or of a codepoint above U+10FFFF. Only the lead bytes ED
         # and F4 begin both valid and excluded sequences.
         " ( (?> (?> [\x20\x21\x23-\x5b\x5d-\xec\xee-\xf3]* )
                 (?> (?: (?: \xed[\x80-\x9f] | \xf4[\x80-\x8f] )
                         (?> [\x20\x21\x23-\x5b\x5d-\xec\xee-\xf3]* ) ){0,64} ) ) ) "

         # number, unless it continues as only a JSON5 number can
      |  ( (?> -? (?> 0 | [1-9][0-9]* ) (?> \.[0-9]+ )? (?> [eE][+-]?[0-9]+ )? ) ) (?! [.xX] )

      |  ( true | false | null )

         # any other string
      |  (")

      |  ( [\[\x7b] )
      |  ( [\]\x7d] )
      |  (,)
      |  (:)

         # comment
      |  ( / [/*] )

         # JSON5 string
      |  (')

         # JSON5 number
      |  ( [+-]?
           (?: Infinity
           |   NaN
           |   0[xX][0-9a-fA-F]+
           |   (?: (?> 0 | [1-9][0-9]* ) (?: \.[0-9]* )? | \.[0-9]+ ) (?: [eE][+-]?[0-9]+ )?
           )
         )

         # JSON5 whitespace: VT, FF, U+00A0, U+1680, U+2000-200A, U+2028,
         # U+2029, U+202F, U+205F, U+3000, U+FEFF
      |  ( (?> (?: [\x0b\x0c]
               |   \xc2\xa0
               |   \xe1\x9a\x80
               |   \xe2\x80[\x80-\x8a\xa8\xa9\xaf]
               |   \xe2\x81\x9f
               |   \xe3\x80\x80
               |   \xef\xbb\xbf
               ){1,64} ) )

         # JSON5 identifier needing more work
      |  ( [\$_A-Za-z\\\x80-\xff] )
      )
   }xgc) {
      my $T= $#-;
      my $v;
      # Prefix comma: only after a value inside a container
      if (defined $1) {
         unless ($st == 1 && $ref) { pos($$text)= $-[1]; last }
         push @$t, $-[1], $+[1], 0 if $t;
         $st= 0;
      }
      # Prefix key and colon
      if (defined $4) {
         $at= defined $2? $-[2]-1 : $-[3];
         # Is a member due? (at the start of an object, or after its comma)
         if ($st == 0 && $is_obj) {
            # A plain "key", or else an identifier
            if (defined $2) {
               # Must non-ASCII text keep an escaped spelling? Then take the
               # key as a string token, leaving the colon and value for later.
               if ($esc && $2 =~ tr/\x80-\xff//) {
                  pos($$text)= $at;
                  $key= $self->_string($text, $j5);
                  push @$t, $at, pos($$text), 0 if $t;
                  $st= 2;
                  next;
               }
               $key= $2;
               utf8::decode($key) if $wide && $key =~ tr/\x80-\xff//;
               push @$t, $at, $+[2]+1, 0, $-[4], $+[4], 0 if $t;
            }
            # An identifier key: JSON5 only
            elsif ($j5) {
               $key= JGraft::JSON::String->_new($3, $3, $ascii, 3);
               push @$t, $at, $+[3], 0, $-[4], $+[4], 0 if $t;
            }
            else { pos($$text)= $at; last }
            $st= 3;
         }
         # Was a comma, closing bracket, or colon due instead?
         elsif ($st == 1 || $st == 2) { pos($$text)= $at; last }
         # Otherwise a value was due
         else {
            # In place of a value: the value it begins with, if any, and then
            # a colon (or the rest of the word) where none can be.
            my $stop= $-[4];
            # An identifier is a value only if it begins with a literal
            if (defined(my $word= $3)) {
               $word =~ /\A(?:true|false|null)/ || $j5 && $word =~ /\A(?:Infinity|NaN)/
                  or _fail($text, 'Expected JSON value', $at);
               $stop= $at+$+[0] if $+[0] < length $word;
            }
            _fail($text, $ref? 'Expected JSON closing delimiter' : 'Unexpected trailing data', $stop);
         }
      }
      $at= $-[5];
      # A plain string that must keep an escaped spelling is not plain
      $T= 9 if $esc && $T == 6 && $6 =~ tr/\x80-\xff//;
      # Tokens 12-18: neither a value nor a closing bracket (the uncommon half)
      if ($T > 11) {
         # 12-13: a comma or colon outside a prefix
         if ($T < 14) {
            # Comma: only after a value inside a container. Colon: only after a key.
            unless ($T == 12? $st == 1 && $ref : $st == 2) { pos($$text)= $at; last }
            push @$t, $at, $at+1, 0 if $t;
            $st= $T == 12? 0 : 3;
            next;
         }
         # 14: a comment, where comments are allowed
         if ($T == 14) {
            unless ($cm) { pos($$text)= $at; last }
            # Line comment, or else block comment
            if (substr($$text, $at+1, 1) eq '/') {
               # To a line terminator, including U+2028 and U+2029.
               1 while $$text =~ /\G(?>(?:[^\n\r\xe2]+|\xe2(?!\x80[\xa8\xa9])){1,64})/gc;
            }
            else {
               my $stop= index($$text, '*/', $at+2);
               $stop < 0 and _fail($text, 'Unterminated JSON comment', $at);
               pos($$text)= $stop+2;
            }
            push @$t, $at, pos($$text), 0 if $t;
            next;
         }
         # 15-18: JSON5 tokens. They become 9 (string), 5 (number, spelled by
         # its extent), or stay 18 (key).
         if ($j5) {
            # 17: whitespace
            next if $T == 17;
            # 15-16: quote or number
            if ($T < 17) { $T= $T == 15? 9 : 5 }
            # 18: an identifier, only where a member is due
            elsif ($st || !$is_obj) { pos($$text)= $at; last }
         }
         # Strict JSON: does the JSON5 number begin with a JSON number? Take that.
         elsif ($T == 16 && $16 =~ /\A-?(?>0|[1-9][0-9]*)(?>\.[0-9]+)?(?>[eE][+-]?[0-9]+)?/) {
            pos($$text)= $at+$+[0];
            $T= 5;
         }
         # Strict JSON: no other JSON5 token
         else { pos($$text)= $at; last }
      }
      # 11: a closing bracket
      if ($T == 11) {
         # It must match the open container, and follow a value, the opening
         # bracket, or (where comments are allowed) a trailing comma.
         unless ($ref && !($11 eq '}' xor $is_obj)
            && ($st == 1 || $st == 0 && (!$n || $cm))
         ) { pos($$text)= $at; last }
         if ($t) { $t->[3*$open+2]= @$t/3; push @$t, $at, $at+1, 0 }
         $v= $ref;
         $first= $open;
         ($ref, $into, $is_obj, $n, $open, $key)= @{pop @stack};
      }
      # 5-10, 18: the start of a value, or a key the prefix did not take
      else {
         # Is a value due? (after a colon, or as an element or the root)
         unless ($st == 3 || $st == 0 && !$is_obj) {
            # Was a comma, closing bracket, or colon due instead?
            if ($st) { pos($$text)= $at; last }
            # A member is due, so this is its key: a plain string,
            if ($T == 6) {
               $key= $6;
               utf8::decode($key) if $wide && $key =~ tr/\x80-\xff//;
            }
            # any other string,
            elsif ($T == 9) { pos($$text)= $at; $key= $self->_string($text, $j5) }
            # or in JSON5 an identifier, which true, Infinity, etc. also are
            elsif ($j5 && ($T == 18 || $T == 8 || $T == 5 && substr($$text, $at, 1) =~ /[IN]/)) {
               pos($$text)= $at;
               $key= $self->_key($text, $j5);
            }
            else { pos($$text)= $at; last }
            push @$t, $at, pos($$text), 0 if $t;
            $st= 2;
            next;
         }
         # 5-7: a plain string or a number
         if ($T < 8) {
            # 6: plain string, decoded if it has non-ASCII bytes
            if ($T == 6) {
               $v= $6;
               utf8::decode($v) if $wide && $v =~ tr/\x80-\xff//;
               push @$t, $at, $+[0], 0 if $t;
            }
            # 7: number, or 5: a number spelled by the extent of the match
            else {
               $v= bless {
                  token => ($T == 7? $7 : substr($$text, $at, pos($$text)-$at)),
                  max_number_digits => $maxn,
                  number_overflow => $ovf,
               }, 'JGraft::JSON::Number';
               if ($t) {
                  push @$t, $at, pos($$text), 0;
                  @{$v}{qw(src at)}= ($id, $at);
               }
            }
         }
         # 8-9: a literal or any other string
         elsif ($T < 10) {
            # 8: true, false, or null
            if ($T == 8) {
               $v= $8 eq 'true'? $JSON::PP::true : $8 eq 'false'? $JSON::PP::false : undef;
               push @$t, $at, $+[0], 0 if $t;
            }
            # 9: a string with escapes, or with a JSON5 spelling
            else {
               pos($$text)= $at;
               $v= $self->_string($text, $j5);
               if ($t) {
                  push @$t, $at, pos($$text), 0;
                  @{$v}[5, 6]= ($id, $at) if ref $v;
               }
            }
         }
         # 10: an opening bracket
         else {
            $maxdepth && @stack >= $maxdepth and croak 'JSON exceeds max_depth';
            push @stack, [$ref, $into, $is_obj, $n, $open, $key];
            my $tie;
            # Object, array retaining layout, or plain array
            if ($is_obj= $10 eq '{') {
               $into= $tie= tie my %object, 'JGraft::JSON::Object';
               $ref= \%object;
            }
            elsif ($t) {
               $tie= tie my @array, 'JGraft::JSON::Array';
               $into= $tie->{items};
               $ref= \@array;
            }
            else { $ref= $into= [] }
            if ($t) {
               $open= @$t/3;
               push @$t, $at, $at+1, 0;
               @{$tie}{qw(doc open)}= ($doc, $open);
               $tie->{orig}= [] if $is_obj;
            }
            $n= $st= 0;
            next;
         }
      }
      # Store the finished value: as a member, an element, or the root
      if ($is_obj) {
         my $slot= $into->_append("$key", $key, $v);
         $into->{orig}[$slot]= $n if $t;
      }
      elsif ($ref) { push @$into, $v }
      else { $root= $v; $done= 1; last }
      ++$n;
      $st= 1;
   }
   unless ($done) {
      # No token, or one out of place: $st says what was due.
      $$text =~ /\G[ \t\r\n]*/gc;
      $at= pos($$text);
      _fail($text,
           $st == 1? 'Expected JSON closing delimiter'
         : $st == 2? 'Expected JSON colon'
         : $st == 0 && $is_obj? (
              $j5 && substr($$text, $at, 1) !~ /["']/? 'Expected JSON key' : 'Expected JSON string'
           )
         : 'Expected JSON value',
         $at);
   }
   my $last= $t && @$t/3-1;
   $first= $last unless ref($root) eq 'HASH' || ref($root) eq 'ARRAY';
   _gap($text, $t, $cm, $j5);
   pos($$text) == length($$text) or _fail($text, 'Unexpected trailing data', pos($$text));
   return ($root, $first, $last);
}
# Skip whitespace and comments, recording comment tokens when retaining layout.
# JSON5 whitespace adds U+00A0, U+FEFF, the line separators U+2028 and U+2029,
# and the space separators U+1680, U+2000-U+200A, U+202F, U+205F, and U+3000.
# Repeats of alternatives are bounded, for the regex stack of old interpreters.
sub _gap {
   my ($text, $t, $cm, $j5)= @_;
   return $$text =~ /\G[ \t\r\n]*/gc unless $cm;
   while (1) {
      if ($j5) {
         1 while $$text =~ /\G(?>(?:[\t\n\x0b\x0c\r ]+|\xc2\xa0|\xe1\x9a\x80|\xe2\x80[\x80-\x8a\xa8\xa9\xaf]
            |\xe2\x81\x9f|\xe3\x80\x80|\xef\xbb\xbf){1,64})/gcx;
      }
      else { $$text =~ /\G[ \t\r\n]*/gc }
      my $start= pos($$text);
      my $kind= substr($$text, $start, 2);
      if ($kind eq '//') {
         # To a line terminator, including U+2028 and U+2029.
         pos($$text)= $start+2;
         1 while $$text =~ /\G(?>(?:[^\n\r\xe2]+|\xe2(?!\x80[\xa8\xa9])){1,64})/gc;
      }
      elsif ($kind eq '/*') {
         my $stop= index($$text, '*/', $start+2);
         $stop < 0 and _fail($text, 'Unterminated JSON comment', $start);
         pos($$text)= $stop+2;
      }
      else { last }
      push @$t, $start, pos($$text), 0 if $t;
   }
}
# Both string parsers begin at pos and leave pos after the token.
sub _key {
   no warnings 'utf8';
   my ($self, $text, $j5)= @_;
   my $start= pos($$text);
   my $first= substr($$text, $start, 1);
   return $self->_string($text, $j5) if $first eq '"' || !$j5 || $first eq "'";
   # JSON5 identifier names, including \u escapes for identifier characters.
   # Identifier characters are found among the decoded characters of the
   # longest run that could hold them.
   1 while $$text =~ /\G(?>(?:[\$_A-Za-z0-9\x80-\xff]+|\\u[0-9a-fA-F]{4}){1,64})/gc;
   my $run= substr($$text, $start, pos($$text)-$start);
   utf8::decode($run) if $run =~ tr/\x80-\xff//;
   $run =~ /\G(?:$ID_START|\\u[0-9a-fA-F]{4})/gc or _fail($text, 'Expected JSON key', $start);
   while ($run =~ /\G(?>(?:$ID_PART+|\\u[0-9a-fA-F]{4}){1,128})/gc) { }
   my $token= substr($run, 0, pos($run));
   my $bytes= $token;
   utf8::encode($bytes);
   pos($$text)= $start+length $bytes;
   (my $value= $token) =~ s/\\u([0-9a-fA-F]{4})/chr(hex($1))/eg;
   $value =~ /\A$ID_START$ID_PART*\z/ or _fail($text, 'Invalid JSON5 identifier', $start);
   return JGraft::JSON::String->_new($value, $token, $self->{ascii}, 3);
}
sub _string {
   no warnings 'utf8';
   my ($self, $text, $j5)= @_;
   my $start= pos($$text);
   my $quote= substr($$text, $start, 1);
   $quote eq '"' || ($quote eq "'" && $j5) or _fail($text, 'Expected JSON string', $start);
   my $json5= $quote eq "'";
   my $end;
   pos($$text)= $start+1;
   unless ($json5) {
      # Bounded repeats avoid the recursive regex engine's stack limits on old
      # interpreters, for both long plain strings and long runs of escapes.
      while ($$text =~ /\G(?>(?:[^"\\\x00-\x1f]+|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4})){1,128})/gc) { }
      $end= pos($$text);
      $json5= $j5 && substr($$text, $end, 1) ne '"';
   }
   if ($json5) {
      pos($$text)= $start+1;
      my $plain= $quote eq '"'? qr/[^"\\\n\r]+/ : qr/[^'\\\n\r]+/;
      while ($$text =~ /\G(?>(?:$plain|\\(?:x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|0(?![0-9])|\r\n|[^0-9xu])){1,128})/gc) { }
      $end= pos($$text);
   }
   substr($$text, $end, 1) eq $quote or _fail($text, 'Expected JSON string', $start);
   pos($$text)= $end+1;
   # The scans above are indifferent to multi-byte sequences; escapes are
   # interpreted among the token's characters.
   my $token= substr($$text, $start, $end+1-$start);
   if ($token =~ tr/\x80-\xff//) {
      $token =~ /\xf4[\x90-\xbf]|[\xf5-\xff]/ and croak 'Codepoint exceeds Unicode maximum';
      utf8::decode($token);
   }
   my $value= substr($token, 1, -1);
   if ($json5) {
      $value =~ s{\\(?:u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][cdefCDEF][0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|x([0-9a-fA-F]{2})|(\r\n|.))}
         {defined($4)? chr(hex($4)) : _escape($1,$2,$3,$5,1)}seg;
   }
   else {
      $value =~ s{\\(?:u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][cdefCDEF][0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|(["\\/bfnrt]))}
         {_escape($1,$2,$3,$4)}eg;
   }
   return $value if $token =~ /[\x{d800}-\x{dfff}]/;
   return JGraft::JSON::String->_new($value, $token, $self->{ascii}, 1) if $json5;
   return $token eq $self->_quote($value)? $value
      : JGraft::JSON::String->_new($value, $token, $self->{ascii});
}
my %ESCAPES=('"'=>'"','\\'=>'\\','/'=>'/',b=>"\x08",f=>"\x0c",n=>"\n",r=>"\r",t=>"\x09");
my %ESCAPES5=(%ESCAPES,v=>"\x0b",'0'=>"\0","\n"=>'',"\r"=>'',"\r\n"=>'',"\x{2028}"=>'',"\x{2029}"=>'');
sub _escape {
   no warnings 'utf8';
   my ($hi,$lo,$cp,$simple,$json5)=@_;
   return chr(0x10000+((hex($hi)-0xd800)<<10)+hex($lo)-0xdc00) if defined $hi;
   return chr(hex($cp)) if defined $cp;
   return $ESCAPES{$simple} unless $json5;
   return exists($ESCAPES5{$simple})? $ESCAPES5{$simple} : $simple;
}
# Whitespace and comments around the root value are kept with the root
# container, number, or string (wrapping a plain string), and discarded for
# null and booleans.
sub _attach_document {
   my ($self,$doc,$out,$first,$last)=@_;
   my $t=$doc->{t};
   $doc->{root}=[$first,$last];
   return $out if $t->[3*$first]==0 && $t->[3*$last+1]==length($doc->{text});
   if (ref($out) eq 'HASH' || ref($out) eq 'ARRAY') { }
   elsif (blessed($out) && $out->isa('JGraft::JSON::Number')) { $out->{doc}=$doc }
   elsif (blessed($out) && $out->isa('JGraft::JSON::String')) { $out->[4]=$doc }
   elsif (defined($out) && !ref($out)) {
      $out=JGraft::JSON::String->_new($out,$self->_quote($out),$self->{ascii},0,$doc,$doc->{id},$t->[3*$first]);
   }
   return $out;
}

# ---- Encoding ----

sub _quote {
   no warnings 'utf8';
   my ($self,$v)=@_;
   my %simple=(8=>'\\b',9=>'\\t',10=>'\\n',12=>'\\f',13=>'\\r',34=>'\\"',92=>'\\\\');
   my $out='"';
   for my $ch (split //,"$v") {
      my $cp=ord($ch);
      $cp<=0x10ffff or croak 'Codepoint exceeds Unicode maximum';
      if (exists $simple{$cp}) { $out.=$simple{$cp} }
      elsif ($cp<32 || ($cp>=0xd800 && $cp<=0xdfff) || ($self->{ascii} && $cp>127)) {
         $out.=$cp<=0xffff?sprintf('\\u%04x',$cp)
            :sprintf('\\u%04x\\u%04x',0xd800+(($cp-0x10000)>>10),0xdc00+(($cp-0x10000)&1023));
      }
      else { $out.=$ch }
   }
   return $out.'"';
}
sub encode {
   my ($self,$v)=@_;
   my $text=$self->{preserve_whitespace} || $self->{pretty} || $self->{comments}
      ? $self->_document($v) : $self->_encode($v,1,{});
   if ($self->{utf8}) { utf8::encode($text) }
   $self->{max_size} && length($text)>$self->{max_size} and croak 'JSON exceeds max_size';
   return $text;
}
# Scalar token in the requested output dialect; undef for containers.
sub _token {
   my ($self,$v,$key)=@_;
   return 'null' unless defined $v;
   return $v?'true':'false' if JSON::PP::is_bool($v);
   if (blessed($v)) {
      return $self->{json5} || $v->is_json? $v->token : $v->json_token if $v->isa('JGraft::JSON::Number');
      if ($v->isa('JGraft::JSON::String')) {
         my $flags=$v->[3] || 0;
         return $v->[1] if $v->[2]==$self->{ascii} && (!($flags & 1) || $self->{json5}) && (!($flags & 2) || $key);
         return $self->_quote($v->[0]);
      }
      if (JGraft::Util::is_number_object($v)) {
         return JGraft::Util::to_decimal_string($v,$self->{max_number_digits}) if is_finite($v);
         $self->{json5} or croak 'Cannot encode a non-finite JSON number';
         return $v->is_nan? 'NaN' : $v->is_inf('-')? '-Infinity' : 'Infinity';
      }
      croak 'Unsupported JSON object '.ref($v);
   }
   my $type=type_mask($v);
   return $self->_quote($v) if $type==TYPE_STRING;
   if ($type==TYPE_NUMBER) {
      unless (is_finite($v)) {
         $self->{json5} or croak 'Cannot encode a non-finite JSON number';
         return $v!=$v? 'NaN' : $v>0? 'Infinity' : '-Infinity';
      }
      return JSON::PP->new->allow_nonref->encode($v);
   }
   $type==TYPE_ARRAY || $type==TYPE_OBJECT or croak 'Unsupported JSON reference '.ref($v);
   return undef;
}
# Compact encoding without layout or comments.
sub _encode {
   my ($self,$v,$depth,$active)=@_;
   my $token=_token($self,$v);
   return $token if defined $token;
   my $type=ref($v) eq 'ARRAY'? TYPE_ARRAY : TYPE_OBJECT;
   $self->_depth($depth);
   my $id=refaddr($v);
   $active->{$id} and croak 'Cannot encode cyclic JSON data';
   local $active->{$id}=1;
   if ($type==TYPE_ARRAY) {
      my $tie=tied @$v;
      my $items=$tie && $tie->isa('JGraft::JSON::Array')? $tie->{items} : $v;
      my @out;
      for my $i (0..$#$items) {
         exists $items->[$i] or croak 'Cannot encode a sparse JSON array';
         push @out,$self->_encode($items->[$i],$depth+1,$active);
      }
      return '['.join(',',@out).']';
   }
   my $tie=tied %$v;
   my @out;
   if ($tie && $tie->isa('JGraft::JSON::Object')) {
      for (my $i=$tie->{head};defined $i;$i=$tie->{seq}[$i+1]) {
         $JGraft::JSON::Object::EXEC->_tick(1) if $JGraft::JSON::Object::EXEC;
         push @out,_token($self,$tie->{tokens}[$i],1).':'.$self->_encode($tie->{tokens}[$i+1],$depth+1,$active);
      }
   }
   else {
      push @out,$self->_quote($_).':'.$self->_encode($v->{$_},$depth+1,$active) for sort keys %$v;
   }
   return '{'.join(',',@out).'}';
}

# Layout-aware encoding appends to a state record:
#   out     text so far          col     current column
#   ind     current line indent  pure    current line holds only indent so far
#   nl      a line comment requires a newline before more tokens
#   unit    indent step of the enclosing container
#   ml/sp   enclosing retained container is multi-line / uses spaces
#   active/flat  cycle detection and memoized inline renderings
sub _document {
   my ($self,$v)=@_;
   my $st={out=>'',col=>0,ind=>'',pure=>1,nl=>0,active=>{},flat=>{},clean=>{},ml=>0,sp=>0,reserve=>0};
   my $root=_root_document($v);
   my $doc=$root? document_layout($root) : [];
   my $ctx={base=>'',use_ws=>$self->{preserve_whitespace},moved=>0};
   $self->_put_gap($st,$doc->[0],$ctx,'',"\n",'');
   $self->_put_value($st,$v,1);
   $self->_put_gap($st,$doc->[1],$ctx,'');
   $self->_put_gap($st,$doc->[2],$ctx,'',"\n");
   $st->{out}.="\n" if $st->{nl};
   return $st->{out};
}
# The document whose surrounding layout belongs to a root value.
sub _root_document {
   my $v=shift;
   my $tie=ref($v) eq 'HASH'? tied(%$v) : ref($v) eq 'ARRAY'? tied(@$v) : undef;
   if ($tie) {
      my $doc=_is_layout_tie($tie) && $tie->{doc};
      return $doc && $doc->{root} && $tie->{open}==$doc->{root}[0]? $doc : undef;
   }
   return $v->{doc} if blessed($v) && $v->isa('JGraft::JSON::Number');
   return $v->[4] if blessed($v) && $v->isa('JGraft::JSON::String');
   return undef;
}
sub _is_layout_tie { $_[0]->isa('JGraft::JSON::Object') || $_[0]->isa('JGraft::JSON::Array') }
sub _layout_of {
   my $v=shift;
   my $tie=ref($v) eq 'HASH'? tied(%$v) : ref($v) eq 'ARRAY'? tied(@$v) : undef;
   return unless $tie && _is_layout_tie($tie);
   return ($tie) unless $tie->{doc};
   return ($tie,(container_layout($tie))[0]);
}
sub _put {
   my ($self,$st,$text)=@_;
   return unless length $text;
   if ($st->{nl}) {
      $st->{nl}=0;
      unless ($text =~ /\A[ \t]*[\r\n]/) {
         return if $text =~ /\A[ \t]+\z/;
         $text =~ s/\A[ \t]+//;
         $text="\n".$st->{ind}.$text;
      }
   }
   $st->{out}.=$text;
   # The last character, kept separately: on older Perls, offsets from the end of
   # a growing UTF-8 string cost a scan of the whole string.
   $st->{last}=substr($text,-1);
   my $nl=rindex($text,"\n");
   if ($nl>=0) {
      my $rest=substr($text,$nl+1);
      $rest =~ /\A([ \t]*)/;
      @{$st}{qw(ind pure col)}=($1,length($1)==length($rest),length $rest);
   }
   else {
      if ($st->{pure}) {
         $text =~ /\A([ \t]*)/;
         $st->{ind}.=$1;
         $st->{pure}=length($1)==length($text);
      }
      $st->{col}+=length $text;
   }
}
sub _put_ws {
   my ($self,$st,$ws,$ctx,$default)=@_;
   if (!defined($ws) || !$ctx->{use_ws}) { $ws=$default }
   elsif (substr($ws,0,1) eq "\0") {
      my $nl=rindex($ws,"\n");
      $ws=substr($ws,1,$nl).$ctx->{base}.substr($ws,$nl+1);
   }
   elsif ($ctx->{moved} && $ws =~ /\n/) { $ws=$default }
   $self->_put($st,$ws);
}
sub _put_comment {
   my ($self,$st,$c)=@_;
   if ($c =~ /\A\0([ \t]*)\0/) {
      my $old=$1;
      $c=substr($c,length($old)+2);
      my $new=$st->{ind};
      $c =~ s/\n\Q$old\E/\n$new/g if $new ne $old;
   }
   $self->_put($st,$c);
   $st->{nl}=1 if substr($c,0,2) eq '//';
}
# Default whitespace is $default before the next token and $inner before each
# comment ($first before the first one). Comments in leading gaps start lines.
sub _put_gap {
   my ($self,$st,$gap,$ctx,$default,$inner,$first)=@_;
   return $self->_put_ws($st,$gap,$ctx,$default) unless ref $gap;
   my $n=@$gap;
   unless ($self->{comments}) {
      $self->_put_ws($st,$gap->[-1],$ctx,$default) if $n%2;
      return;
   }
   $inner=' ' unless defined $inner;
   $first=$inner unless defined $first;
   for my $i (0..$n-1) {
      if ($i%2) { $self->_put_comment($st,$gap->[$i]) }
      else { $self->_put_ws($st,$gap->[$i],$ctx,$i==$n-1? $default : $i? $inner : $first) }
   }
}
sub _put_value {
   my ($self,$st,$v,$depth)=@_;
   my $token=$self->_token($v);
   return $self->_put($st,$token) if defined $token;
   $self->_depth($depth);
   if ($self->{preserve_whitespace}) {
      my $tie=ref($v) eq 'HASH'? tied(%$v) : tied(@$v);
      return if $tie && _is_layout_tie($tie) && $tie->{doc} && $tie->{doc}{cw} && $self->_verbatim($st,$v,$tie,$depth);
   }
   my ($tie,$outer)=_layout_of($v);
   my $use_ws=$self->{preserve_whitespace} && $outer && $outer->{ws};
   # The pretty renderer does its own cycle detection.
   if (!$use_ws && ($self->{pretty} || ($self->{preserve_whitespace} && $st->{ml}))) {
      return $self->_put($st,$self->_render($st,$v,$st->{col},$self->{wrap},$st->{reserve},$st->{ind},$depth));
   }
   my $id=refaddr($v);
   $st->{active}{$id} and croak 'Cannot encode cyclic JSON data';
   local $st->{active}{$id}=1;
   return $self->_put_container($st,$v,$tie,$outer,$depth,$use_ws);
}
# Members as [key, value, record]; keys are undef for arrays. For a decoded
# container, records come from matching current members with the original
# tokens, unless $plain (only keys and values are needed).
sub _members {
   my ($self,$v,$tie,$plain)=@_;
   my $object=ref($v) eq 'HASH';
   my @out;
   if ($object) {
      return map [$_,$v->{$_}],sort keys %$v unless $tie;
      my $tokens=$tie->{tokens};
      for (my $i=$tie->{head};defined $i;$i=$tie->{seq}[$i+1]) {
         $JGraft::JSON::Object::EXEC->_tick(1) if $JGraft::JSON::Object::EXEC;
         push @out,[$tokens->[$i],$tokens->[$i+1],$i];
      }
   }
   else {
      my $items=$tie? $tie->{items} : $v;
      for my $i (0..$#$items) {
         exists $items->[$i] or croak 'Cannot encode a sparse JSON array';
         push @out,[undef,$items->[$i]];
      }
   }
   return @out if $plain || !$tie || !$tie->{doc};
   my $doc=$tie->{doc};
   my (undef,$records,$members,$at)=container_layout($tie);
   my @origins;
   if ($object) {
      my $orig=$tie->{orig};
      for my $m (@out) {
         my $j=$orig->[$m->[2]];
         push @origins,[$j,defined($j) && $tie->{mod} && !_same_value($doc,$members,$at,$m->[1],$j)];
      }
   }
   elsif (!$tie->{mod}) { @origins=map [$_,0],0..$#out }
   else { @origins=_align($doc,$members,$at,\@out) }
   my $recs=arrange($records,\@origins,$object? K_PRE : V_PRE,$object? 6 : 3);
   $out[$_][2]=$recs->[$_] for 0..$#out;
   return @out;
}
# The original member index of a value recognizable by identity: a container
# by its position, a decoded number or string by its document and offset.
# Returns an empty list for other values, which can only be compared as text.
sub _identify {
   my ($doc,$members,$at,$v)=@_;
   my $t=$doc->{t};
   if (ref($v) eq 'HASH' || ref($v) eq 'ARRAY') {
      my $tie=ref($v) eq 'HASH'? tied(%$v) : tied(@$v);
      return undef unless $tie && _is_layout_tie($tie) && $tie->{doc} && $tie->{doc}==$doc;
      my $j=$at->{$t->[3*$tie->{open}]};
      return defined($j) && $members->[$j][2]==$tie->{open}? $j : undef;
   }
   return unless blessed($v);
   my ($src,$off,$token);
   if ($v->isa('JGraft::JSON::Number')) { ($src,$off,$token)=@{$v}{qw(src at token)} }
   elsif ($v->isa('JGraft::JSON::String')) { ($src,$off,$token)=@{$v}[5,6,1] }
   else { return }
   return undef unless defined($off) && $src==$doc->{id};
   my $j=$at->{$off};
   return undef unless defined $j;
   # The document id is an address; the token check rules out a reused one.
   return _member_text($doc,$members,$j) eq $token? $j : undef;
}
sub _member_text {
   my ($doc,$members,$j)=@_;
   my ($v,$end)=@{$members->[$j]}[2,3];
   return '' if $v!=$end;
   my $t=$doc->{t};
   my $text=substr($doc->{text},$t->[3*$v],$t->[3*$v+1]-$t->[3*$v]);
   utf8::decode($text) if $doc->{wide};
   return $text;
}
# The original spelling a plain decoded scalar would have had.
sub _plain_text {
   my ($doc,$v)=@_;
   return 'null' unless defined $v;
   return $v?'true':'false' if JSON::PP::is_bool($v);
   return undef if ref($v) || type_mask($v)!=TYPE_STRING;
   return _quote({ascii=>$doc->{ascii}},$v);
}
sub _same_value {
   my ($doc,$members,$at,$v,$j)=@_;
   my @id=_identify($doc,$members,$at,$v);
   return defined($id[0]) && $id[0]==$j if @id;
   my $text=_plain_text($doc,$v);
   return defined($text) && $text eq _member_text($doc,$members,$j);
}
# Original member indexes for the elements of a modified array. Plain scalars
# match the next unused original with the same spelling.
sub _align {
   my ($doc,$members,$at,$elements)=@_;
   my (%used,%queue,$queued,@origins);
   my $next=0;
   for my $e (@$elements) {
      my $v=$e->[1];
      my @id=_identify($doc,$members,$at,$v);
      my $j;
      if (@id) { $j=$id[0] }
      elsif (defined(my $text=_plain_text($doc,$v))) {
         if ($next<@$members && !$used{$next} && _member_text($doc,$members,$next) eq $text) { $j=$next }
         else {
            unless ($queued++) {
               for my $k (0..$#$members) {
                  my $m=_member_text($doc,$members,$k);
                  push @{$queue{$m}},$k if length $m;
               }
            }
            my $q=$queue{$text} || [];
            shift @$q while @$q && ($q->[0]<$next || $used{$q->[0]});
            $j=$q->[0];
         }
      }
      $j=undef if defined($j) && $used{$j};
      if (defined $j) { $used{$j}=1; $next=$j+1 }
      push @origins,[$j,0];
   }
   return @origins;
}
# The indent step of a retained container's members, if they have one.
sub _unit {
   my ($self,$st,$members,$lead)=@_;
   for my $m (@$members) {
      my $ws=defined($m->[2])? final_ws($m->[2][$lead]) : undef;
      next unless defined($ws) && substr($ws,0,1) eq "\0";
      my $rel=substr($ws,rindex($ws,"\n")+1);
      return $rel if length $rel;
   }
   return defined($st->{unit})? $st->{unit} : ' ' x $self->{indent_length};
}
# Retained layout ($use_ws), or default whitespace: one member per line when
# pretty, else compact. Comments are placed according to their attachments.
sub _put_container {
   my ($self,$st,$v,$tie,$outer,$depth,$use_ws)=@_;
   my $object=ref($v) eq 'HASH';
   my $base=$st->{ind};
   my $ctx={base=>$base,use_ws=>$use_ws,
      moved=>$use_ws && defined($outer->{base}) && $outer->{base} ne $base};
   my @members=$self->_members($v,$tie);
   my $lead_field=$object? K_PRE : V_PRE;
   my $ml=$use_ws? $outer->{ml} : $self->{pretty};
   my $sp=!$use_ws && ($self->{pretty} || $st->{sp});
   my $unit=$self->_unit($st,$use_ws? \@members : [],$lead_field);
   my $lead=$ml? "\n".$base.$unit : $sp? ' ' : '';
   my $colon=$ml || $sp? ' ' : '';
   # Whole-line comments without retained whitespace go on member-indent lines.
   my $line="\n".$base.$unit;
   $self->_put($st,$object?'{':'[');
   $self->_put_gap($st,$outer->{open},$ctx,'') if $outer;
   unless (@members) {
      $self->_put_gap($st,$outer && $outer->{close},$ctx,'');
      return $self->_put($st,$object?'}':']');
   }
   my $comma=$outer && $outer->{tc} && ($self->{json5} || $self->{comments});
   for my $i (0..$#members) {
      my ($key,$value,$rec)=@{$members[$i]};
      $rec=$EMPTY if $use_ws && !defined $rec;
      $self->_put_gap($st,$rec && $rec->[$lead_field],$ctx,$i || $ml? $lead : '',$line,$line);
      if ($object) {
         $self->_put($st,$self->_token($key,1));
         $self->_put_gap($st,$rec && $rec->[C_PRE],$ctx,'');
         $self->_put($st,':');
         $self->_put_gap($st,$rec && $rec->[C_POST],$ctx,'');
         $self->_put_gap($st,$rec && $rec->[V_PRE],$ctx,$colon,$line);
      }
      {
         local @{$st}{qw(unit ml sp reserve)}=($unit,$ml,($st->{last}||'') eq ' '? 1 : 0,1);
         $self->_put_value($st,$value,$depth+1);
      }
      $self->_put_gap($st,$rec && $rec->[M_PRE],$ctx,'');
      $self->_put($st,',') if $i<$#members || $comma;
      $self->_put_gap($st,$rec && $rec->[POST],$ctx,'');
   }
   $self->_put_gap($st,$outer && $outer->{close},$ctx,$ml? "\n".$base : '',$line);
   $self->_put($st,$object?'}':']');
}
# An unmodified container is copied from its original text when the output
# dialect matches the document's and its line indent is unchanged (or it has
# no line breaks).
sub _verbatim {
   my ($self,$st,$v,$tie,$depth)=@_;
   my $doc=$tie->{doc};
   return 0 if $tie->{mod} || ($doc->{j5} && !$self->{json5}) || ($self->{ascii}?1:0)!=$doc->{ascii}
      || ($doc->{cm} && !($doc->{cc} && $self->{comments}));
   my ($t,$open)=($doc->{t},$tie->{open});
   my $start=$t->[3*$open];
   my $text=substr($doc->{text},$start,$t->[3*$t->[3*$open+2]+1]-$start);
   return 0 if $text =~ /\n/ && JGraft::JSON::_Layout::_line_indent(\$doc->{text},$start) ne $st->{ind};
   return 0 unless $self->_clean($st,$v,$doc,$depth);
   utf8::decode($text) if $doc->{wide};
   $self->_put($st,$text);
   return 1;
}
sub _clean {
   my ($self,$st,$v,$doc,$depth)=@_;
   my $id=refaddr($v);
   return $st->{clean}{$id} if exists $st->{clean}{$id};
   my $tie=ref($v) eq 'HASH'? tied(%$v) : tied(@$v);
   my $ok=$tie && _is_layout_tie($tie) && $tie->{doc} && $tie->{doc}==$doc && !$tie->{mod};
   if ($ok) {
      $self->_depth($depth);
      my @values;
      if (ref($v) eq 'HASH') {
         for (my $i=$tie->{head};defined $i;$i=$tie->{seq}[$i+1]) { push @values,$tie->{tokens}[$i+1] }
      }
      else { @values=@{$tie->{items}} }
      for (@values) {
         next unless ref($_) eq 'HASH' || ref($_) eq 'ARRAY';
         next if $self->_clean($st,$_,$doc,$depth+1);
         $ok=0;
         last;
      }
   }
   return $st->{clean}{$id}=$ok? 1 : 0;
}
# Render a container needing _put_container into a string, starting at $col
# on a line indented by $base.
sub _sub_render {
   my ($self,$st,$v,$col,$base,$depth)=@_;
   my ($tie,$outer)=_layout_of($v);
   my %sub=(%$st,out=>'',last=>'',col=>$col,ind=>$base,pure=>!$col,nl=>0);
   $self->_put_container(\%sub,$v,$tie,$outer,$depth,$self->{preserve_whitespace} && $outer && $outer->{ws});
   return $sub{out};
}
# Containers that cannot use the generic layout rules.
sub _special {
   my ($self,$v)=@_;
   my ($tie,$outer)=_layout_of($v);
   return 0 unless $tie;
   return 1 if $self->{preserve_whitespace} && $outer && $outer->{ws};
   return $self->{comments} && $outer && has_comments([map $_->[2],$self->_members($v,$tie)],$outer)? 1 : 0;
}

# Generic layout rules shared with jg-format: a container stays on one line if
# it fits; otherwise members wrap at the width, unless a member is itself a
# multi-member container (or cannot be inlined), in which case each member
# gets its own line.
sub _shape {
   my ($self,$v)=@_;
   my ($tie)=_layout_of($v);
   my @members=$self->_members($v,$tie,1);
   return ('[',']',[map +{values=>[$_->[1]]},@members]) if ref($v) eq 'ARRAY';
   return ('{','}',[map +{values=>[bless(\(my $k=$_->[0]),'JGraft::JSON::_Key'),$_->[1]],separator=>': '},@members]);
}
sub _size {
   my $v=shift;
   my ($tie)=_layout_of($v);
   return ref($v) eq 'ARRAY'? scalar @{$tie? $tie->{items} : $v} : $tie? scalar keys %{$tie->{index}} : scalar keys %$v;
}
sub _inline {
   my ($self,$st,$v,$depth)=@_;
   return $self->_token(${$v},1) if ref($v) eq 'JGraft::JSON::_Key';
   my $token=$self->_token($v);
   return $token if defined $token;
   my $id=refaddr($v);
   return $st->{flat}{$id} if exists $st->{flat}{$id};
   $self->_depth($depth);
   $st->{active}{$id} and croak 'Cannot encode cyclic JSON data';
   local $st->{active}{$id}=1;
   if ($self->_special($v)) {
      my ($tie,$outer)=_layout_of($v);
      return $st->{flat}{$id}=undef if !$outer->{ws} || $outer->{ml};
      my $text=$self->_sub_render($st,$v,0,'',$depth);
      return $st->{flat}{$id}=$text =~ /\n/? undef : $text;
   }
   my ($open,$close,$groups)=$self->_shape($v);
   return $st->{flat}{$id}=undef if $self->_stacked($st,$groups,$depth);
   my @parts;
   for my $group (@$groups) {
      my @items;
      for my $item (@{$group->{values}}) {
         my $text=$self->_inline($st,$item,$depth+1);
         return $st->{flat}{$id}=undef unless defined $text;
         push @items,$text;
      }
      push @parts,join($group->{separator} || ', ',@items);
   }
   return $st->{flat}{$id}=$open.join(', ',@parts).$close;
}
sub _stacked {
   my ($self,$st,$groups,$depth)=@_;
   for my $group (@$groups) {
      for my $item (@{$group->{values}}) {
         next if ref($item) eq 'JGraft::JSON::_Key';
         return 1 if (ref($item) eq 'ARRAY' || ref($item) eq 'HASH') && _size($item)>1;
         return 1 unless defined $self->_inline($st,$item,$depth+1);
      }
   }
   return 0;
}
sub _group {
   my ($self,$st,$group,$indent,$width,$depth)=@_;
   my ($out,$current)=('',length $indent);
   my $separator=$group->{separator} || ', ';
   for my $value (@{$group->{values}}) {
      my $flat=$self->_inline($st,$value,$depth);
      if (length $out) {
         my $fits=defined($flat) && (!$width || $current+length($separator)+length($flat)<=$width-1);
         if (!$fits && (ref($value) eq 'ARRAY' || ref($value) eq 'HASH')) {
            $fits=!$width || $current+length($separator)+1<=$width-1;
         }
         if ($fits) { $out.=$separator; $current+=length $separator }
         else {
            (my $punctuation=$separator) =~ s/ +\z//;
            $out.=$punctuation."\n".$indent.$st->{unit};
            $current=length($indent.$st->{unit});
         }
      }
      my $text=$self->_render($st,$value,$current,$width,1,$indent,$depth);
      $out.=$text;
      $current=$text =~ /\n([^\n]*)\z/? length($1) : $current+length($text);
   }
   return $out;
}
sub _render {
   my ($self,$st,$v,$column,$width,$reserve,$base,$depth)=@_;
   local $st->{unit}=defined($st->{unit})? $st->{unit} : ' ' x $self->{indent_length};
   my $flat=$self->_inline($st,$v,$depth);
   my $container=ref($v) eq 'ARRAY' || ref($v) eq 'HASH';
   return $flat if !$container || (defined($flat) && (!$width || $column+length($flat)<=$width-$reserve));
   return $self->_sub_render($st,$v,$column,$base,$depth) if $self->_special($v);
   my $id=refaddr($v);
   $self->_depth($depth);
   local $st->{active}{$id}=1;
   my ($open,$close,$groups)=$self->_shape($v);
   return $open.$close unless @$groups;
   my $indent=$base.$st->{unit};
   $width*=2 while $width && $width-length($indent)<40;
   my $stacked=$self->_stacked($st,$groups,$depth);
   my $out=$open;
   my $written=0;
   my $current=$column+length($open);
   for my $group (@$groups) {
      my (@items,$force);
      $force=$stacked;
      for my $item (@{$group->{values}}) {
         my $text=$self->_inline($st,$item,$depth+1);
         if (defined $text) { push @items,$text } else { $force=1 }
      }
      my $text=@items==@{$group->{values}}? join($group->{separator} || ', ',@items) : undef;
      if (!$force && defined($text) && (!$width || $current+($written?2:0)+length($text)<=$width-1)) {
         $out.=', ' if $written;
         $out.=$text;
         $current+=($written?2:0)+length($text);
      }
      else {
         $out.=',' if $written;
         $text=$self->_group($st,$group,$indent,$width,$depth+1);
         $out.="\n".$indent.$text;
         $current=$text =~ /\n([^\n]*)\z/? length($1) : length($indent)+length($text);
      }
      $written=1;
   }
   return $out."\n".$base.$close;
}

=head1 SYNOPSIS

  my $json= JGraft::JSON->new(utf8 => 1);
  my $data= $json->decode($bytes);
  my $edited= JGraft::jgexec($graft, $data);
  my $bytes_out= $json->encode($edited);

  # Edit a commented JSON5 file, keeping its layout and comments
  my $json5= JGraft::JSON->new(json5 => 1, comments => 1, preserve_whitespace => 1);
  my $config= $json5->decode($text);
  $config->{port}= 8080;
  print $json5->encode($config);

=head1 DESCRIPTION

A JSON codec for applications needing exact decimal numbers and retention of
untouched string escape spellings, member order, and duplicate object keys.
It can optionally accept JSON5, and retain whitespace and comments so that a
decoded document can be edited and written back with minimal changes.

By default the codec is strict: comments, bare keys, trailing commas,
non-finite numbers, and other JSON extensions are rejected, and whitespace is
not retained. Top-level scalars are allowed. Only adjacent escaped UTF-16
surrogate pairs are combined; unpaired surrogates remain separate codepoints
and are always escaped on output.

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
JGraft's copy-on-write. Arrays are ordinary unless layout is retained, when they
are tied to L<JGraft::JSON::Array>.

Math::BigInt, Math::BigFloat, and Math::BigRat can also be encoded. Their values
are emitted exactly; a rational without a terminating decimal expansion is an
error. Callers must explicitly round such values before serialization.

=head2 JSON5

With C<json5>, the decoder accepts JSON5: comments, trailing commas, identifier
keys, single-quoted strings with JSON5 escapes and line continuations,
hexadecimal numbers, leading or trailing decimal points, explicit plus signs,
C<Infinity>, C<NaN>, and Unicode whitespace. Original spellings are retained.
The encoder emits them unchanged only when C<json5> is also enabled for
encoding; otherwise it converts them to JSON (quoting keys and strings, and
converting numbers with L<JGraft::JSON::Number/json_token>). Non-finite numbers,
whether decoded or native Perl values, can only be encoded as JSON5.

=head2 Whitespace and comments

C<preserve_whitespace> retains whitespace while decoding and reproduces it
while encoding. C<comments> retains comments while decoding (accepting comments
and trailing commas even without C<json5>, as in "JSONC") and emits them while
encoding. Either option keeps a copy of the document text with the positions of
its tokens, and ties decoded arrays so that edits can be detected. Without
them, decoding does no layout work. Containers that have not been modified are
reproduced directly from the original text when the output options allow it.

Whitespace is retained before every token, including colons and commas.
Comments starting their own line attach to the following token, including a
closing bracket; other comments attach to the preceding token (a value rather
than its comma). Comments in an empty container attach to its opening bracket.
Whitespace and comments around the root value are kept with the root container,
number, or string, which becomes a L<JGraft::JSON::String> wrapper if needed;
they are discarded for a root C<null> or boolean.

When encoding a modified container, members are matched with the original
tokens: containers, numbers, and wrapped strings by their identity, and other
values by spelling. Matched members keep their whitespace and comments, even
when reordered. Replacing a value discards the comments attached to it;
removing a member discards its whitespace too. New members copy the whitespace
of the previous member. See L<JGraft::JSON::Object> and
L<JGraft::JSON::Array>.

Line indents beginning with the container's own line indent are treated as
relative to it, as are continuation lines of block comments relative to their
first line. A container moved to a different indent level therefore keeps a
consistent layout. Other whitespace containing newlines is replaced by default
layout after such a move.

Containers without retained whitespace (newly added substructure) use the
C<pretty> layout rules when inside a multi-line container, using its indent
step, or are written on one line otherwise. Without C<preserve_whitespace>,
encoding ignores retained whitespace, using C<pretty> layout or compact output.
Retained comments are still emitted when C<comments> is enabled; comments
force a container onto multiple lines in pretty output.

=head2 Pretty layout

C<pretty> uses the same rules as F<jg-format> for ordinary JSON: a container
that fits within C<wrap> columns stays on one line; otherwise each member gets
its own line if any member is a container with more than one member, and short
members are packed onto lines of at most C<wrap> columns otherwise. Indents use
C<indent_length> spaces. Untied hashes use sorted keys.

=constructor new

Options are:

=over

=item C<ascii> - escape non-ASCII output (default false)

=item C<utf8> - accept and produce UTF-8 bytes instead of characters (default false)

=item C<json5> - accept JSON5, and permit JSON5 spellings in output (default false)

=item C<comments> - retain and emit comments, accepting JSONC (default false)

=item C<preserve_whitespace> - retain and reproduce whitespace (default false)

=item C<pretty> - lay out output on multiple lines where needed (default false)

=item C<indent_length> - pretty indent step in spaces (default 2)

=item C<wrap> - pretty line width, zero for unlimited (default 79)

=item C<max_depth> - nesting limit (default 256)

=item C<max_size> - input/output length limit (default 0, unlimited)

=item C<max_number_digits> - numeric conversion limit (default 10000)

=item C<number_overflow> - C<reject> or C<native> (default C<reject>)

=back

Zero disables a size/depth/digit bound. Number limits apply to numeric conversion and fresh big
number emission; original numeric tokens can always round-trip without expansion.
The native overflow policy permits approximate arithmetic, not loss of the
retained token. Escapes are preserved when using the same C<ascii> configuration;
changing that configuration re-encodes wrapped strings normally.

=method decode

Decode one complete document, dying on invalid input or a configured limit.
The input scalar is never modified.

=method encode

Encode an acyclic JSON tree. Without C<pretty>, C<preserve_whitespace>, or
C<comments>, the output has no optional whitespace. Untied hashes use sorted
keys; tied decoded objects preserve source order and untouched duplicates. Dies
on unsupported objects, sparse arrays, or (except in JSON5) non-finite values.

=method ascii

=method utf8

=method json5

=method comments

=method preserve_whitespace

=method pretty

Set the corresponding flag (true when called without an argument), returning the
codec for chaining. These methods do not change already decoded values.

=method indent_length

=method wrap

Set the corresponding nonnegative integer, returning the codec for chaining.

=cut

1;
