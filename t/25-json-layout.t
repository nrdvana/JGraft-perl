use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use Storable 'dclone';
use JGraft::JSON;
use JGraft::Util qw(is_finite is_integer to_decimal_string to_native_number);

# Backslashes are spelled \x5c so source text never contains Unicode escapes.
my $bs="\x5c";
my $full=JGraft::JSON->new(json5=>1,comments=>1,preserve_whitespace=>1);
my $jsonc=JGraft::JSON->new(comments=>1,preserve_whitespace=>1);
my $strict=JGraft::JSON->new;
sub roundtrip { my ($codec,$text)=@_; $codec->encode($codec->decode($text)) }

my $json5_doc=<<"END";
// JSON5 configuration
{
  unquoted: 'single ${bs}'quoted${bs}' ${bs}x41',
  ${bs}u0065scaped: "line${bs}
continued",
  numbers: [0x1F, -0XaB, .5, 5., +1, 1e3, -Infinity, NaN, +Infinity,],
  "nbsp":\x{a0}"x",
  control: '${bs}v${bs}0${bs}q',
  nested: {deep: [/* inline */ true, null, false,],},
}
END

subtest 'exact round trips' => sub {
   for my $case (
      [$jsonc,qq({\n  "a": [1, 2],\n  "b": {}\n}\n),'pretty JSON with final newline'],
      [$jsonc,qq( { "a" : 1 ,"b":[ ] , "c" :{ } } ),'irregular spacing around every token'],
      [$jsonc,qq({\n\t"a": {\n\t\t"x": [\n\t\t\t1\n\t\t]\n\t}\n}),'tab indents'],
      [$jsonc,qq({\r\n  "a": 1, // c\r\n  /* m\r\n     n */\r\n  "b": 2\r\n}\r\n),'CRLF lines and comments'],
      [$jsonc,qq([\n\n  1,\n\n\n  2  ,  3\n]),'blank lines and space before commas'],
      [$jsonc,qq(// top\n[1, /* inline */ 2, // eol\n  3 /* last */ ] // after\n// end\n),'comment attachments'],
      [$jsonc,qq([ // nothing\n]),'comment in empty container'],
      [$jsonc,qq({"a": 1,}),'JSONC trailing comma'],
      [$jsonc,qq({\n    "a": [\n  1\n    ]\n}),'indent not relative to its container'],
      [$full,$json5_doc,'JSON5 syntax, spellings, and comments'],
      [$full,qq(  /* root */ 'str' // after\n),'root string layout'],
      [$full,qq(\n12.50 // number\n),'root number layout'],
      [$full,qq([1,2,{"a":[]}]),'compact input'],
   ) {
      my ($codec,$text,$name)=@$case;
      is(roundtrip($codec,$text),$text,$name);
   }
   is(roundtrip($full,"null // dropped\n"),'null','root null discards document layout');
   is(roundtrip($full,"\ntrue\n"),'true','root boolean discards document layout');
   my $ws=JGraft::JSON->new(json5=>1,preserve_whitespace=>1);
   is(roundtrip($ws,qq([\n  1, // c\n  2\n]\n)),qq([\n  1,\n  2\n]\n),'whitespace without comments');
   my $c=JGraft::JSON->new(comments=>1);
   is(roundtrip($c,qq([\n  1, // c\n  2\n])),qq([1, // c\n2]),'comments without whitespace are compact');
   is(JGraft::JSON->new(comments=>1,pretty=>1)->encode($c->decode(qq(// head\n{"a": [1, /* x */ 2], "b": 3} // tail\n))),
      qq(// head\n{\n  "a": [\n    1, /* x */\n    2\n  ],\n  "b": 3\n} // tail\n),
      'pretty layout places retained comments; commented containers use multiple lines');
};

subtest 'decoding options' => sub {
   my $plain=$strict->decode('[1,{"a":[2]}]');
   ok(!tied(@$plain) && !tied(@{$plain->[1]{a}}),'arrays stay ordinary without layout options');
   ok(!exists((tied %{$plain->[1]})->{outer}),'objects carry no layout without layout options');
   ok(!tied(@{JGraft::JSON->new(json5=>1)->decode('[1 /* x */]')}),'JSON5 alone skips comments without capture');
   my $commented=JGraft::JSON->new(comments=>1)->decode('[1]');
   isa_ok(tied(@$commented),'JGraft::JSON::Array');
   ok(!(tied @$commented)->{doc}{cw},'comments alone do not capture whitespace');
   for my $bad ('[1 /* x */]','[1,]','{"a":1,}',"// x\n1") {
      ok(dies { JGraft::JSON->new(preserve_whitespace=>1)->decode($bad) },"strict decoding rejects $bad");
   }
   ok(lives { JGraft::JSON->new(comments=>1)->decode("[1, // x\n]") },'comments option accepts JSONC');
   for my $bad ("{'a':1","[1,,2]",'{a b:1}','01','0x','[.]','"'.$bs.'1"',"'a",'/* x',
      "{${bs}u0031a:1}","\"a\nb\"","[+]",'[Infinityx]') {
      ok(dies { JGraft::JSON->new(json5=>1)->decode($bad) },"JSON5 rejects $bad");
   }
   like(dies { $full->decode('[1 /* open') },qr/Unterminated JSON comment/,'unterminated comment');
   like(dies { $full->decode("{${bs}u0031:1}") },qr/identifier/,'escaped identifier must form an identifier');
   my $utf8=JGraft::JSON->new(utf8=>1,json5=>1,comments=>1,preserve_whitespace=>1);
   my $bytes=qq({caf\xc3\xa9: 'd\xc3\xa9j\xc3\xa0' /* \xe2\x9c\x93 */}\n);
   is($utf8->encode($utf8->decode($bytes)),$bytes,'UTF-8 JSON5 round trip');
};

subtest 'JSON5 spellings and conversion' => sub {
   my $data=$full->decode($json5_doc);
   is($data->{unquoted},"single 'quoted' A",'single-quoted string escapes');
   is($data->{escaped},"linecontinued",'escaped identifier key and line continuation');
   is($data->{control},"\x0b\0q",'JSON5 character escapes');
   is([map "$_",@{$data->{numbers}}[0..5]],['31','-171','0.5','5','1','1e3'],'numbers stringify as JSON');
   delete $data->{numbers};
   my $json=$strict->encode($data);
   is($json,'{"unquoted":"single \'quoted\' A","escaped":"linecontinued","nbsp":"x",'
      .'"control":"\\u000b\\u0000q","nested":{"deep":[true,null,false]}}','strict output converts JSON5 spellings');
   is(JGraft::JSON->new(comments=>1,preserve_whitespace=>1)->encode($data),<<"END",'JSONC output keeps layout, converts spellings');
// JSON5 configuration
{
  "unquoted": "single 'quoted' A",
  "escaped": "linecontinued",
  "nbsp":\x{a0}"x",
  "control": "\\u000b\\u0000q",
  "nested": {"deep": [/* inline */ true, null, false,],},
}
END
   like(dies { $strict->encode($full->decode('[Infinity]')) },qr/non-finite/,'strict output rejects decoded Infinity');
   is($full->encode([9**9**9,-9**9**9]),'[Infinity,-Infinity]','JSON5 encodes native infinities');
   is(JGraft::JSON->new(json5=>1)->encode([9**9**9-9**9**9]),'[NaN]','JSON5 encodes native NaN');
   require Math::BigRat;
   is(JGraft::JSON->new(json5=>1)->encode([Math::BigRat->binf('-')]),'[-Infinity]','JSON5 encodes big infinities');
   like(dies { $strict->encode(9**9**9) },qr/non-finite/,'strict output rejects native infinity');

   my $key=(tied %{$full->decode('{bare: 1}')})->{tokens}[0];
   is([$key->token,$key->is_json,$key->json_token],['bare',0,'"bare"'],'identifier key spelling and JSON spelling');
   is($full->encode([$key]),'["bare"]','identifier spelling is only used for keys');
   my $quoted=$full->decode("'it'");
   is([$quoted->token,$quoted->json_token],["'it'",'"it"'],'single-quoted string JSON spelling');
   my $escaped=$strict->decode('"'.$bs.'u0041"');
   is([$escaped->is_json,$escaped->json_token],[1,'"'.$bs.'u0041"'],'JSON escape spelling is valid JSON');
};

subtest 'numbers' => sub {
   for my $case (
      ['0x1F','31'],['-0x1f','-31'],['+0x0','0'],['.5','0.5'],['-.5e-3','-0.5e-3'],['5.','5'],
      ['5.e2','5e2'],['+1','1'],['1.50','1.50'],['0XFFFFFFFFFFFFFFFFFFFF','1208925819614629174706175'],
   ) {
      my $n=JGraft::JSON::Number->new($case->[0],json5=>1);
      is($n->json_token,$case->[1],"json_token $case->[0]");
      is($n->value->bstr,Math::BigRat->new($case->[1])->bstr,"value $case->[0]");
      ok(is_finite($n),"$case->[0] is finite");
   }
   ok(JGraft::JSON::Number->new('1.5')->is_json && !JGraft::JSON::Number->new('+1',json5=>1)->is_json,'is_json');
   like(dies { JGraft::JSON::Number->new('0x1') },qr/Invalid JSON number/,'JSON5 tokens require the json5 option');
   is([map { JGraft::JSON::Number->new($_,json5=>1)?1:0 } qw(0x0 0xA .0 0. +0e5 .1 NaN -Infinity)],[0,1,0,0,0,1,1,1],'truth values');
   ok(is_integer(JGraft::JSON::Number->new('0x10',json5=>1)),'hexadecimal is an integer');
   ok(!is_integer(JGraft::JSON::Number->new('.5',json5=>1)),'leading decimal point is not an integer');
   is(to_native_number(JGraft::JSON::Number->new('0x10',json5=>1)),16,'native conversion of hexadecimal');
   is(to_decimal_string(JGraft::JSON::Number->new('+.25',json5=>1)),'0.25','decimal string uses JSON spelling');
   is(JGraft::JSON::Number->new('0x10',json5=>1)+1,17,'arithmetic uses the numeric value');
   for my $token ('Infinity','-Infinity','+Infinity','NaN') {
      my $n=JGraft::JSON::Number->new($token,json5=>1);
      ok(!is_finite($n),"$token is not finite");
      is("$n",$token,"$token stringifies as its token");
      like(dies { $n->json_token },qr/non-finite/,"$token has no JSON spelling");
   }
   ok(JGraft::JSON::Number->new('-Infinity',json5=>1)->value->is_inf('-'),'negative infinity value');
   ok(JGraft::JSON::Number->new('NaN',json5=>1)->value->is_nan,'NaN value');
   ok(0+JGraft::JSON::Number->new('Infinity',json5=>1)->_native>1e308,'native infinity');
   my $big=JGraft::JSON->new(json5=>1,max_number_digits=>5)->decode('0xFFFFFF');
   is($big->token,'0xFFFFFF','oversized hexadecimal retains its token');
   like(dies { $big->json_token },qr/max_number_digits/,'oversized hexadecimal conversion is bounded');
   like(dies { $big->value },qr/max_number_digits/,'oversized hexadecimal value is bounded');
   my $native=JGraft::JSON->new(json5=>1,max_number_digits=>5,number_overflow=>'native')->decode('0xFFFFFF');
   is($native->value,16777215,'native policy approximates oversized hexadecimal');
};

subtest 'value replacement and removal' => sub {
   my $data=$jsonc->decode(qq({\n  // key\n  "a": /* colon */ 1, // value\n  "b": 2\n}));
   $data->{a}=5;
   is($jsonc->encode($data),qq({\n  // key\n  "a": /* colon */ 5,\n  "b": 2\n}),
      'replacing a value keeps key comments and whitespace, discards value comments');
   delete $data->{a};
   is($jsonc->encode($data),qq({\n  "b": 2\n}),'deleting a member discards its comments');
   my $dups=$jsonc->decode(qq({\n  "x": 1, // first\n  "y": 2,\n  // last x\n  "x": 3\n}));
   $dups->{x}=4;
   is($jsonc->encode($dups),qq({\n  "y": 2,\n  // last x\n  "x": 4\n}),'collapsing duplicates discards removed members');
   my $first=$jsonc->decode(qq({ "a": 1, "b": 2 }));
   delete $first->{a};
   is($jsonc->encode($first),qq({ "b": 2 }),'a new first member takes the whitespace after the brace');
   my $close=$jsonc->decode(qq([\n  1\n  // before close\n]));
   pop @$close;
   is($jsonc->encode($close),qq([\n  // before close\n]),'closing-bracket comments survive member removal');
   my $empty=$jsonc->decode(qq([ // note\n]));
   push @$empty,1;
   is($jsonc->encode($empty),qq([ // note\n  1\n]),'empty-container comments stay on the opening bracket');
   my $key=$full->decode(qq({"${bs}u0061": 1}));
   $key->{a}=2;
   is($full->encode($key),qq({"${bs}u0061": 2}),'assignment keeps the key spelling');
   my $clear=$jsonc->decode(qq([1, 2] // tail\n));
   @$clear=();
   is($jsonc->encode($clear),qq([] // tail\n),'clearing keeps container comments');
   push @$clear,3,4;
   is($jsonc->encode($clear),qq([3, 4] // tail\n),'refilled container takes the original separators');
};

subtest 'array operations' => sub {
   my $text=qq([\n  1, // one\n  2, // two\n  3 // three\n]);
   my $a=$jsonc->decode($text);
   is([@$a],[1,2,3],'tied array reads');
   is(scalar(@$a),3,'size');
   ok(exists($a->[2]) && !exists($a->[3]),'exists');
   splice @$a,1,1,'x','y';
   is($jsonc->encode($a),qq([\n  1, // one\n  "x",\n  "y",\n  3 // three\n]),'splice replaces, copies neighbor whitespace');
   is([splice @$a,-2],['y',3],'negative splice offset returns removed elements');
   is($jsonc->encode($a),qq([\n  1, // one\n  "x"\n]),'removed elements discard comments');
   unshift @$a,0;
   is($jsonc->encode($a),qq([\n  0,\n  1, // one\n  "x"\n]),'unshift');
   is(shift(@$a),0,'shift returns value');
   is(pop(@$a),'x','pop returns value');
   $a->[3]='z';
   is([@$a],[1,undef,undef,'z'],'storing past the end extends');
   is($jsonc->encode($a),qq([\n  1, // one\n  null,\n  null,\n  "z"\n]),'extension whitespace');
   $#$a=0;
   is($jsonc->encode($a),qq([\n  1 // one\n]),'truncate');
   is(delete($a->[0]),1,'delete last element');
   is(scalar(@$a),0,'delete of last element shrinks');

   my $line=$jsonc->decode('[ 1, 2 ]');
   unshift @$line,0;
   push @$line,3;
   is($jsonc->encode($line),'[ 0, 1, 2, 3 ]','inserted elements use separator whitespace, not the opening gap');
   my $one=$jsonc->decode('[1]');
   push @$one,2;
   is($jsonc->encode($one),'[1,2]','single-element neighbor');
   my $grow=$jsonc->decode(qq([\n  "a"\n]));
   $#$grow=1;
   is($jsonc->encode($grow),qq([\n  "a",\n  null\n]),'growing with $#array');
};

subtest 'object insertion and new substructure' => sub {
   my $data=$jsonc->decode(qq({\n\t"a": 1\n}\n));
   $data->{b}={list=>[1,2],more=>{x=>[3,4]}};
   is($jsonc->encode($data),qq({\n\t"a": 1,\n\t"b": {\n\t\t"list": [1, 2],\n\t\t"more": {\n\t\t\t"x": [3, 4]\n\t\t}\n\t}\n}\n),
      'new substructure in a multi-line container uses pretty layout and its indent step');
   my $spaced=$jsonc->decode('{ "a": [1, 2], "b": 3 }');
   $spaced->{c}={e=>[1,{f=>2}]};
   is($jsonc->encode($spaced),'{ "a": [1, 2], "b": 3, "c": {"e": [1, {"f": 2}]} }','single-line spaced container');
   my $compact=$jsonc->decode('{"a":[1,2]}');
   $compact->{c}={e=>[1,{f=>2}]};
   push @{$compact->{a}},[5];
   is($jsonc->encode($compact),'{"a":[1,2,[5]],"c":{"e":[1,{"f":2}]}}','compact container');
   my $empty=$jsonc->decode("{\n}");
   $empty->{a}=1;
   is($jsonc->encode($empty),qq({\n  "a": 1\n}),'first member of an empty multi-line object');
   my $narrow=JGraft::JSON->new(preserve_whitespace=>1,indent_length=>4,wrap=>20);
   my $w=$narrow->decode("[\n]");
   push @$w,{a=>[1,2],b=>[3,4]};
   is($narrow->encode($w),qq([\n    {\n        "a": [1, 2],\n        "b": [3, 4]\n    }\n]),
      'pretty options apply to new substructure');
};

subtest 'moving retained containers' => sub {
   my $data=$jsonc->decode(qq({\n\t"a": {\n\t\t"x": [\n\t\t\t1,\n\t\t\t2\n\t\t]\n\t},\n\t"b": [ {"y" : 1} ]\n}));
   push @{$data->{b}},$data->{a}{x};
   $data->{a}{deeper}={q=>$data->{a}{x}};
   is($jsonc->encode($data),
      qq({\n\t"a": {\n\t\t"x": [\n\t\t\t1,\n\t\t\t2\n\t\t],\n\t\t"deeper": {\n\t\t\t"q": [\n\t\t\t\t1,\n\t\t\t\t2\n\t\t\t]\n\t\t}\n\t},\n\t"b": [ {"y" : 1}, [\n\t\t1,\n\t\t2\n\t] ]\n}),
      'relative indents follow the new line indent');
   my $odd=$jsonc->decode(qq({\n    "a": [\n  1\n    ],\n    "b": 0\n}));
   $odd->{b}={x=>$odd->{a}};
   is($jsonc->encode($odd),qq({\n    "a": [\n  1\n    ],\n    "b": {\n        "x": [\n            1\n        ]\n    }\n}),
      'whitespace not relative to its container is replaced after a move');
   my $comment=$jsonc->decode(qq({\n  "a": {\n    /* one\n       two */\n    "x": 1\n  }\n}));
   is($jsonc->encode($comment->{a}),qq({\n  /* one\n     two */\n  "x": 1\n}),'multi-line comment lines follow the indent');
};

subtest 'recognizing original elements' => sub {
   my $a=$jsonc->decode(qq([\n  "a", // A\n  "b", // B\n  "c" // C\n]));
   splice @$a,1,1;
   is($jsonc->encode($a),qq([\n  "a", // A\n  "c" // C\n]),'plain strings are recognized after a removal');
   my $n=$jsonc->decode(qq([\n  1, // one\n  {"x": 2}, // two\n  true // three\n]));
   @$n=reverse @$n;
   is($jsonc->encode($n),qq([\n  true, // three\n  {"x": 2}, // two\n  1 // one\n]),'reordered elements keep their comments');
   my $same=$jsonc->decode(qq([1, /* a */ 2, 3 /* c */]));
   @$same=@$same;
   is($jsonc->encode($same),qq([1, /* a */ 2, 3 /* c */]),'reassigning the same elements keeps the layout');
   $same->[2]=9;
   is($jsonc->encode($same),qq([1, /* a */ 2, 9]),'a replaced element loses its comments');
   my $num=$n->[2];
   ok(defined($num->{at}) && !exists($num->{doc}),'numbers record an offset, not the document');
   my $copy=dclone($n);
   pop @$copy;
   is($jsonc->encode($copy),qq([\n  true, // three\n  {"x": 2} // two\n]),'recognition survives Storable');
   my $other=$jsonc->decode(qq([\n  5 // five\n]));
   push @$other,$n->[2];
   is($jsonc->encode($other),qq([\n  5, // five\n  1\n]),'elements from another document are new');
};

subtest 'untouched containers' => sub {
   my $text=qq({\n  "keep": [1,2 ,  3],\n  "edit": {"a": 1, "c": 3}\n}\n);
   my $data=$jsonc->decode($text);
   $data->{edit}{b}=2;
   is($jsonc->encode($data),qq({\n  "keep": [1,2 ,  3],\n  "edit": {"a": 1, "c": 3, "b": 2}\n}\n),'untouched siblings are copied');
   ok(!(tied @{$data->{keep}})->{mod},'reading does not mark a container modified');
   my $clone=(tied @{$data->{keep}})->clone(sub { $_[0] });
   ok(!(tied @$clone)->{mod},'an identity-mapped clone stays unmodified');
   my $mapped=(tied @{$data->{keep}})->clone(sub { "x" });
   ok((tied @$mapped)->{mod},'a changed clone is modified');
   my $strict_out=$strict->encode($full->decode(qq([0x10, /* c */ .5])));
   is($strict_out,'[16,0.5]','JSON5 containers are rebuilt for strict output');
};

subtest 'clone interface and Storable' => sub {
   my $data=$full->decode($json5_doc);
   my $tie=tied %$data;
   ok($tie->can('clone'),'objects implement clone');
   my $array=$data->{numbers};
   my $atie=tied @$array;
   ok($atie->can('clone'),'arrays implement clone');
   my $copy=$atie->clone;
   isa_ok(tied(@$copy),'JGraft::JSON::Array');
   is($full->encode($copy),$full->encode($array),'array clone keeps layout');
   push @$copy,1;
   isnt($full->encode($copy),$full->encode($array),'array clone is independent');
   my $mapped=$tie->clone(sub { ref($_[0])? $_[0] : 'v' });
   is($mapped->{nbsp},'v','object clone maps values');
   is((tied %$mapped)->{outer},$tie->{outer},'object clone shares immutable container layout');
   is($full->encode(dclone($data)),$json5_doc,'Storable round trip keeps layout');
};

# Members matched whole (comma, key, colon, and value in one match) and tokens
# matched singly (here forced by a comment before every token) must build the
# same data.
subtest 'whole-member and single-token matches agree' => sub {
   my @docs=(qq({"a" : [1, "x${bs}"y", true , null],"${bs}u00e9":{}, "b": -1.5e3}),
      qq([ 1, "caf\x{e9}", {"k":[]} , [[], {}] ]),qq(  "root"  ),qq([\n  "s",\n  2\n]\n),
      qq({"s": "${bs}ud834${bs}udd1e", "n": [0, -0.5, 1E+2], "\x{d55c}\x{ae00}": "\x{1d11e}"}),'['.join(',',1..40000).']');
   for my $opts ([comments=>1],[json5=>1],[ascii=>1,comments=>1]) {
      my $codec=JGraft::JSON->new(@$opts);
      my $plain=JGraft::JSON->new(@$opts,comments=>0);
      for my $i (0..$#docs) {
         my $text=$docs[$i];
         (my $stepped=$text) =~ s{("(?:[^"${bs}${bs}]|${bs}${bs}.)*"|[^\s"\[\]{},:]+|[\[\]{},:])}{/*c*/$1}g;
         is($plain->encode($codec->decode($stepped)),$plain->encode($codec->decode($text)),"document $i, @$opts: same data");
      }
   }
   my $layout=JGraft::JSON->new(comments=>1,preserve_whitespace=>1);
   for my $text (qq({ "k\x{e9}" : [ 1 , "\x{4e2d}" ] , /* \x{e9} */ "${bs}u0041" : "\x{1d11e}" , } // end\n),
      qq(\n[ "\x{d55c}", // \x{e9}\n  {"a":null}\n]\n)) {
      my $data=$layout->decode($text);
      is($layout->encode($data),$text,'non-ASCII layout round trip');
      my $t=(ref($data) eq 'HASH'? tied(%$data) : tied(@$data))->{doc}{t};
      my $bytes=$text;
      utf8::encode($bytes);
      my $tokens=join '',map substr($bytes,$t->[3*$_],$t->[3*$_+1]-$t->[3*$_]),0..@$t/3-1;
      utf8::decode($tokens);
      (my $bare=$text) =~ s/\s+//g;
      $tokens =~ s/\s+//g;
      is($tokens,$bare,'token positions are byte offsets covering every token');
   }
   my $deep=('[' x 300).(']' x 300);
   like(dies { $strict->decode($deep) },qr/max_depth/,'depth limit');
   my $nest=JGraft::JSON->new(max_depth=>0)->decode(('[' x 5000).(']' x 5000));
   my $levels=0;
   while (ref $nest) { ++$levels; $nest=$nest->[0] }
   is($levels,5000,'nesting does not use recursion');
   like(dies { $strict->decode('[1,]') },qr/Expected JSON value at character 3/,'strict trailing comma');
   like(dies { $strict->decode(qq(["\x{e9}\x{4e2d}" 1])) },qr/Expected JSON closing delimiter at character 6/,'error offsets count characters');
   like(dies { $strict->decode('{"a":1 "b":2}') },qr/Expected JSON closing delimiter at character 7/,'missing comma');
   like(dies { $strict->decode('{"a" 1}') },qr/Expected JSON colon at character 5/,'missing colon');
   like(dies { $strict->decode('{"a":}') },qr/Expected JSON value at character 5/,'missing member value');
   like(dies { $strict->decode('[1}') },qr/Expected JSON closing delimiter at character 2/,'mismatched bracket');
   like(dies { $strict->decode('[1] x') },qr/Unexpected trailing data at character 4/,'trailing data');
   like(dies { $jsonc->decode('[1 /* x') },qr/Unterminated JSON comment at character 3/,'unterminated comment');
};

subtest 'pretty layout matches jg-format rules' => sub {
   require JGraft::_Format;
   my $pretty=JGraft::JSON->new(pretty=>1);
   for my $data (
      {a=>[1,2],b=>{c=>3,d=>[4,5]},e=>[map "item$_",1..20]},
      [[1,[2,3]],{}],
      [{a=>1},{b=>2}],
      {short=>'x'},
      [map +{id=>$_,tags=>[qw(a b)]},1..3],
   ) {
      is($pretty->encode($data),JGraft::_Format->format_json($data),'same layout as format_json');
   }
   is(JGraft::JSON->new(pretty=>1,wrap=>0)->encode([1..40]),'['.join(', ',1..40).']','unlimited width');
};

subtest 'layout callback' => sub {
   my $enc=sub { my ($data,$cb,%options)=@_; JGraft::JSON->new(pretty=>1,%options,layout=>$cb)->encode($data) };
   my $text_of=sub { my $t=shift; chomp $t; $t };
   my @data=(
      {a=>[1,2],b=>{c=>3,d=>[4,5]},e=>[map "item$_",1..20]},
      [[1,[2,3]],{}], [{a=>1},{b=>2}], {k=>'x' x 90,j=>[1,{q=>'y' x 80}]}, [], 5,
      [map [map "v$_",1..12],1..3],
   );
   my $calls=0;
   for my $wrap (79,30,0) {
      for my $data (@data) {
         my $plain=JGraft::JSON->new(pretty=>1,wrap=>$wrap)->encode($data);
         is($enc->($data,sub { ++$calls },wrap=>$wrap),$plain,"callback changing nothing, wrap $wrap");
         is($enc->($data,sub { $_[0]->prefix; $_[0]->layout; $_[0]->emit; $_[0]->suffix },wrap=>$wrap),$plain,
            "reading every attribute, wrap $wrap");
      }
   }
   ok($calls>100,'callback was called');
   is($enc->($data[0],sub { 1 },pretty=>0),$strict->encode($data[0]),'compact output is unchanged');
   is(JGraft::JSON->new(layout=>sub { 1 })->layout(undef)->encode([1,[2]]),'[1,[2]]','layout accessor');
   like(dies { JGraft::JSON->new(layout=>1) },qr/layout must be a code reference/,'layout option is validated');

   my @seen;
   $enc->({a=>[10,{b=>undef}],c=>'s'},sub {
      my $c=shift;
      push @seen,join(':',$c->depth,map(defined($_)? $_ : '-',$c->idx,$c->name),ref($_) || (defined($_)? $_ : 'null'),
         $c->parent? ref($c->parent->value) : 'root',defined($c->state)? $c->state : '-');
      $c->state($c->depth) if ref;
   });
   is(\@seen,['0:-:-:HASH:root:-','1:0:a:ARRAY:HASH:0','2:0:-:10:ARRAY:1','2:1:-:HASH:ARRAY:1','3:0:b:null:HASH:2',
      '1:1:c:s:HASH:0'],'document order, $_, position, and inherited state');
   my $tree=[1,[2,3,[4]],{a=>5}];
   $calls=0;
   is($enc->($tree,sub { ++$calls; $_[0]->callback(undef) if $_[0]->depth==1 }),JGraft::JSON->new(pretty=>1)->encode($tree),'removing the callback keeps the default output');
   is($calls,4,'and stops calls beneath a node');
   my (@outer,@inner);
   my $inner=sub { push @inner,$_[0]->depth; $_[0]->layout('stack') if ref($_) eq 'ARRAY' };
   my $outer; $outer=sub {
      my $c=shift;
      push @outer,$c->depth;
      ref($c->callback) eq 'CODE' or die 'callback not inherited';
      $c->callback($inner) if defined($c->name) && $c->name eq 'in';
   };
   is($enc->({a=>[1,2],in=>{x=>[1,2]}},$outer),qq|{\n  "a": [1, 2],\n  "in": {\n    "x": [\n      1,\n      2\n    ]\n  }\n}|,'a subtree can have its own callback');
   is([\@outer,\@inner],[[0,1,2,2,1],[2,3,3]],'which replaces the inherited one beneath the node');
   like(dies { $enc->([1],sub { $_[0]->callback(1) }) },qr/callback must be/,'invalid callback rejected');
   like(dies { $enc->([1],sub { $_[0]->parent->callback(undef) if $_[0]->parent }) },qr/Cannot change callback/,
      'callback of a visited node is locked');
   $calls=0;
   $enc->($tree,sub { ++$calls; $_[0]->leaves(0) unless $_[0]->depth });
   is($calls,4,'leaves(0) skips scalars');

   # Operation-style layout: a head beside the bracket, pairs, and a tail
   my $local=["LOCAL","x",1,"y",["ADD",["TEMP","x"],2],["ADD",["TEMP","x"],["TEMP","y"]]];
   my $ops=sub {
      my $c=shift;
      my $p=$c->parent;
      if ($p && ref($p->value) eq 'ARRAY') {
         if ($c->idx==0) { $c->prefix('') }
         elsif ($p->state eq 'pairs' && $p->layout ne 'fit') {
            $c->prefix($c->idx%2 || $c->idx==$#{$p->value}? "\n" : ' ');
         }
      }
      return unless ref eq 'ARRAY';
      $c->state($_->[0] eq 'LOCAL'? 'pairs' : 'op');
      $c->layout('wrap');
      $c->layout('fill') if grep ref eq 'ARRAY' && @$_>2,@$_;
   };
   is($enc->($local,$ops),$text_of->(<<'END'),'head, pairs, and tail from prefixes');
["LOCAL",
  "x", 1,
  "y", ["ADD", ["TEMP", "x"], 2],
  ["ADD", ["TEMP", "x"], ["TEMP", "y"]]
]
END
   is($enc->({lit=>[[{a=>1,b=>[1,2]},"two",[3,4]]]},sub {
      my $c=shift;
      if (ref eq 'ARRAY' && @$_==1 && ref $_->[0] eq 'ARRAY') { $c->layout('fit')->state('hug') }
      elsif (($c->state || '') eq 'hug') { $c->state(undef)->layout('stack') }
   }),$text_of->(<<'END'),'fit around a stacked member hugs its brackets');
{
  "lit": [[
    {
      "a": 1,
      "b": [1, 2]
    },
    "two",
    [3, 4]
  ]]
}
END
   my $nested=[map [$_,$_+1],1..8];
   is($enc->($nested,sub { $_[0]->layout('wrap') if ref },wrap=>50),
      "[[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7],\n  [7, 8], [8, 9]\n]",'wrap packs members the default would stack');
   is($enc->([[1,2],[3,4]],sub { $_[0]->layout('wrap') if ref }),'[[1, 2], [3, 4]]','wrap stays on one line when it fits');
   is($enc->($nested,sub { my $c=shift; $c->layout('stack') if ref && $c->layout('wrap')->layout eq 'fill' },wrap=>50),
      "[\n".join(",\n",map "  [$_, ".($_+1)."]",1..8)."\n]",'reading a wrap layout resolves it');
   is($enc->([1..7],sub { my $c=shift; $c->layout('fit') unless $c->parent; $c->suffix("\n") if $c->depth && $c->idx%2 }),
      "[1, 2,\n  3, 4,\n  5, 6,\n  7]",'a newline suffix is completed with the indent');
   is($enc->($local,sub { my $c=shift; $c->layout('stack') unless $c->parent; $c->callback(undef)->suffix('') if $c->depth==1 && $c->idx==5 }) =~ /\]\]\z/? 1 : 0,
      1,'the last suffix places the closing bracket');
   is($enc->([1,[2,3],{a=>4}],sub { my $c=shift; $c->prefix(' ') if $c->depth==1 && $c->idx; $c->layout('stack') if ref eq 'HASH' },pretty=>0),
      "[1, [2, 3], {\n  \"a\": 4\n}]",'attributes apply without pretty');

   is($enc->($local,sub { ref($_)? $_[0]->layout('wrap') : $_ eq 'ADD' && $_[0]->emit(74) },wrap=>0),
      '["LOCAL", "x", 1, "y", [74, ["TEMP", "x"], 2], [74, ["TEMP", "x"], ["TEMP", "y"]]]','emit replaces a scalar');
   $calls=0;
   is($enc->({k=>[1,2]},sub { my $c=shift; ++$calls; if (ref eq 'ARRAY') { (my $text=$c->emit) =~ tr/[]/()/; $c->emit($text) } }),
      "{\n  \"k\": (1, 2)\n}",'a built emit can be edited');
   is($calls,4,'members were visited once while building it');
   is($enc->([[1,2,3]],sub { my $c=shift; if (ref && $c->depth) { $c->emit; $c->layout('stack')->emit(undef) } }),
      "[\n  [\n    1,\n    2,\n    3\n  ]\n]",'a built emit can be discarded');
   is($enc->({a=>{b=>[1]}},sub { my $c=shift; $c->emit(length $c->indent) unless ref }),'{"a": {"b": [2]}}','indent is relative to the line');
   is($enc->({a=>{b=>[1]}},sub { my $c=shift; ref($_)? $c->layout('stack') : $c->emit(length $c->indent) }),
      "{\n  \"a\": {\n    \"b\": [\n      6\n    ]\n  }\n}",'indent of a nested member');

   like(dies { $enc->([1],sub { $_[0]->parent->prefix(' ') if $_[0]->parent }) },qr/Cannot change prefix: .*already been written/,
      'a written prefix is locked');
   like(dies { $enc->([1],sub { $_[0]->parent->layout('stack') if $_[0]->parent }) },qr/Cannot change layout/,'a used layout is locked');
   is($enc->([1,[2]],sub { $_[0]->parent->suffix(' ') if $_[0]->parent }),'[1, [2] ] ','a suffix stays open to descendants');
   my ($first,@late);
   $enc->([1,2],sub {
      my $c=shift;
      return unless $c->depth;
      if ($c->idx) { push @late,dies { $first->suffix(' ') } } else { $first=$c }
   });
   like($late[0],qr/Cannot change suffix/,'a finished node is locked');
   like(dies { $enc->([1],sub { $_[0]->layout('bogus') }) },qr/layout must be/,'layout values are validated');

   # Comments and retained layout
   is($enc->({a=>1,b=>[1,2],c=>3},sub {
      my $c=shift;
      my $name=defined($c->name)? $c->name : '';
      $c->comments(before=>['// lead']) if $name eq 'b';
      $c->comments(after=>['/* t */']) if !ref && $_ eq '1';
      $c->comments(after=>['// end']) if $name eq 'c';
   },comments=>1),$text_of->(<<'END'),'assigned comments');
{
  "a": 1, /* t */
  // lead
  "b": [1, /* t */ 2],
  "c": 3 // end
}
END
   is($enc->([1],sub { $_[0]->comments(after=>['// x']) }),'[1]','comments need the comments option');
   like(dies { $enc->([1],sub { $_[0]->comments(before=>['nope']) }) },qr/complete \/\/ or/,'comment text is validated');
   like(dies { $enc->([1],sub { $_[0]->comments(open=>[]) }) },qr/cannot be assigned/,'only before and after can be assigned');

   my $text="// top\n{\n  // about a\n  a: 1, // trailing a\n  b: [1, 2,\n      3], /* open */\n  c: {/* in */ x:1 /* out */}\n}\n";
   my $doc=$full->decode($text);
   my $codec=JGraft::JSON->new(json5=>1,comments=>1,preserve_whitespace=>1);
   my %read;
   $codec->layout(sub {
      my $c=shift;
      my $id=join '.',map defined($_)? $_ : '',$c->depth,defined($c->name)? $c->name : $c->idx;
      $read{$id}=[$c->prefix,$c->suffix,$c->layout,map [$c->comments($_)],qw(before after open close)];
   });
   is($codec->encode($doc),$text,'reading attributes keeps retained layout');
   is($read{'1.a'},["\n  ",'',undef,['// about a'],['// trailing a'],[],[]],'retained member whitespace and comments');
   is($read{'1.b'},["\n  ",'','stack',[],['/* open */'],[],[]],'retained multi-line container');
   is($read{'2.2'},["\n      ",'',undef,[],[],[],[]],'retained continuation indent');
   is($read{'1.c'},["\n  ","\n",'fit',[],[],['/* in */'],[]],'retained closing whitespace and inner comments');
   is($read{'2.x'}[4],['/* out */'],'a comment after the last member belongs to it');
   $codec->layout(sub {
      my $c=shift;
      my $name=defined($c->name)? $c->name : '';
      $c->layout('fit') if $name eq 'b';
      $c->prefix("\n\n") if $name eq 'c';
      $c->comments(before=>['/* new */'])->comments(after=>[]) if $name eq 'a';
      $c->emit(2) if $name eq 'x';
   });
   is($codec->encode($doc),"// top\n{\n  /* new */\n  a: 1,\n  b: [1, 2, 3], /* open */\n\n  c: {/* in */ x:2 /* out */}\n}\n",
      'assigned attributes override retained layout');
   $calls=0;
   $codec->layout(sub { ++$calls; $_[0]->callback(undef) });
   is($codec->encode($doc),$text,'a root without a callback beneath it is copied verbatim');
   is($calls,1,'without further calls');
};

subtest 'sortkeys' => sub {
   my $data={b=>1,a=>[1,2],c=>{z=>1,y=>2},id=>7};
   is(JGraft::JSON->new->encode($data),'{"a":[1,2],"b":1,"c":{"y":2,"z":1},"id":7}','default order of untied hashes');
   is(JGraft::JSON->new(sortkeys=>['id','c'])->encode($data),'{"id":7,"c":{"y":2,"z":1},"a":[1,2],"b":1}',
      'listed keys first, in list order, at every level');
   # The comparator finds $a and $b in the package it was compiled in.
   my $reverse=sub { $b cmp $a };
   my $other=eval 'package Local::Elsewhere; sub { length($a) <=> length($b) or $a cmp $b }' or die $@;
   is(JGraft::JSON->new(sortkeys=>$reverse)->encode($data),'{"id":7,"c":{"z":1,"y":2},"b":1,"a":[1,2]}','comparator');
   is(JGraft::JSON->new->sortkeys($other)->encode($data),'{"a":[1,2],"b":1,"c":{"y":2,"z":1},"id":7}',
      'comparator from another package');
   is(JGraft::JSON->new(pretty=>1,wrap=>20,sortkeys=>$reverse)->encode($data),
      qq|{\n  "id": 7,\n  "c": {"z": 1, "y": 2},\n  "b": 1,\n  "a": [1, 2]\n}|,'pretty output');
   my $codec=JGraft::JSON->new(sortkeys=>$reverse);
   is($codec->sortkeys(undef)->encode($data),JGraft::JSON->new->encode($data),'undef restores the default');
   like(dies { JGraft::JSON->new(sortkeys=>1) },qr/sortkeys must be/,'invalid sortkeys rejected');

   my $text="{ b: 1, // bee\n  a: [1, 2],\n  a: 3, c: {y:1, x:2} }\n";
   my $doc=$full->decode($text);
   is($full->encode($doc),$text,'decoded objects keep their order by default');
   my $sorted=JGraft::JSON->new(json5=>1,comments=>1,preserve_whitespace=>1,sortkeys=>['c']);
   is($sorted->encode($doc),"{ c: {x:2, y:1},\n  a: [1, 2],\n  a: 3,\n  b: 1 // bee\n  }\n",
      'decoded objects are sorted on request, keeping duplicates and attached layout');
   is(JGraft::JSON->new(sortkeys=>['c'])->encode($doc),'{"c":{"x":2,"y":1},"a":[1,2],"a":3,"b":1}','and in compact output');

   my @seen;
   my $cb=sub {
      my $c=shift;
      push @seen,ref($c->sortkeys) if $c->depth == 2;
      $c->sortkeys($reverse) if defined($c->name) && $c->name eq 'c';
      $c->sortkeys(undef) if defined($c->name) && $c->name eq 'n';
   };
   my $nested={c=>{b=>1,a=>{y=>1,x=>2},n=>{q=>1,p=>2}},a=>{y=>1,x=>2}};
   is(JGraft::JSON->new(layout=>$cb,sortkeys=>['y'])->encode($nested),
      '{"a":{"y":1,"x":2},"c":{"n":{"p":2,"q":1},"b":1,"a":{"y":1,"x":2}}}','the cursor overrides it for a subtree');
   is([sort @seen],[qw(ARRAY ARRAY CODE CODE CODE)],'and descendants read the inherited value');
   is(JGraft::JSON->new(pretty=>1,layout=>$cb,sortkeys=>['y'])->encode($nested),
      qq|{\n  "a": {"y": 1, "x": 2},\n  "c": {\n    "n": {"p": 2, "q": 1},\n    "b": 1,\n    "a": {"y": 1, "x": 2}\n  }\n}|,'also when pretty');
   is(JGraft::JSON->new(pretty=>1,layout=>sub { $cb->($_[0]); $_[0]->callback(undef) if $_[0]->depth == 1 },sortkeys=>['y'])->encode($nested),
      qq|{\n  "a": {"y": 1, "x": 2},\n  "c": {\n    "n": {"q": 1, "p": 2},\n    "b": 1,\n    "a": {"y": 1, "x": 2}\n  }\n}|,'and beneath a node whose callback was removed');
   like(dies { JGraft::JSON->new(layout=>sub { $_[0]->sortkeys({}) })->encode({}) },qr/sortkeys must be/,
      'invalid cursor sortkeys rejected');
};

subtest 'omitting nodes' => sub {
   my $data={k=>[1,2,3],h=>{k1=>1,k2=>2,k3=>3}};
   my %expect=(
      '1'=>['{"h":{"k2":2,"k3":3},"k":[2,3]}',qq|{\n  "h": {"k2": 2, "k3": 3},\n  "k": [2, 3]\n}|],
      '3'=>['{"h":{"k1":1,"k2":2},"k":[1,2]}',qq|{\n  "h": {"k1": 1, "k2": 2},\n  "k": [1, 2]\n}|],
      '2'=>['{"h":{"k1":1,"k3":3},"k":[1,3]}',qq|{\n  "h": {"k1": 1, "k3": 3},\n  "k": [1, 3]\n}|],
      '12'=>['{"h":{"k3":3},"k":[3]}',qq|{\n  "h": {"k3": 3},\n  "k": [3]\n}|],
      '23'=>['{"h":{"k1":1},"k":[1]}',qq|{\n  "h": {"k1": 1},\n  "k": [1]\n}|],
      '123'=>['{"h":{},"k":[]}',qq|{\n  "h": {},\n  "k": []\n}|],
   );
   for my $omit (sort keys %expect) {
      my $cb=sub { $_[0]->emit('') if !ref($_) && index($omit,$_) >= 0 };
      is(JGraft::JSON->new(layout=>$cb)->encode($data),$expect{$omit}[0],"omit $omit");
      is(JGraft::JSON->new(layout=>$cb,pretty=>1,wrap=>12)->encode($data),$expect{$omit}[1],"omit $omit, pretty");
   }
   my $stack=sub { $_[0]->layout('stack') if ref($_) eq 'ARRAY'; $_[0]->emit('') if !ref($_) && $_ > 1 };
   is(JGraft::JSON->new(layout=>$stack,pretty=>1)->encode([1,2,3]),"[\n  1\n]",'closing whitespace follows omitted members');
   is(JGraft::JSON->new(layout=>sub { $_[0]->emit('') if ref($_) eq 'ARRAY' })->encode({a=>[1],b=>2}),'{"b":2}',
      'an omitted container is not visited');

   my $text="{ b: 1, // bee\n  a: 3,\n  c: {y:1, x:2} }\n";
   my $doc=$full->decode($text);
   my $codec=JGraft::JSON->new(json5=>1,comments=>1,preserve_whitespace=>1);
   my $names=sub { my $re=shift; sub { $_[0]->emit('') if defined($_[0]->name) && $_[0]->name =~ $re } };
   is($codec->layout($names->(qr/^[bx]/))->encode($doc),"{ a: 3,\n  c: {y:1} }\n",'first member of a retained layout');
   is($codec->layout($names->(qr/^[cy]/))->encode($doc),"{ b: 1, // bee\n  a: 3 }\n",'last member of a retained layout');
   is($codec->layout($names->(qr/^a/))->encode($doc),"{ b: 1, // bee\n  c: {y:1, x:2} }\n",'middle member');
   my $trailing=$codec->decode("[1, 2,]\n");
   is($codec->layout(sub { $_[0]->emit('') if ($_[0]->idx || 0) == 1 })->encode($trailing),"[1,]\n",'a retained trailing comma stays');
   my $reset=sub { my $c=shift; return if ref($_); $c->emit('')->emit(undef); $c->emit('') if $c->emit eq '2' };
   is(JGraft::JSON->new(layout=>$reset)->encode([1,2,3]),'[1,3]','undef only discards the assignment');
};

done_testing;
