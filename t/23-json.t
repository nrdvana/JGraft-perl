use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec jgparse);
use JGraft::JSON;
use JGraft::Exec;
use JGraft::Util qw(:types type_mask is_finite is_integer is_number_object
   estimate_number_digits to_native_number to_rational to_decimal_string);
use Math::BigRat;
use Math::BigInt;
use Math::BigFloat;
use Scalar::Util qw(refaddr weaken);

my $json=JGraft::JSON->new;
my $text=' { "a": 1.000, "b": "\\u0062", "a": 1e-99, "c": "x\\/y" } ';
my $input=$json->decode($text);
my $original='{"a":1.000,"b":"\\u0062","a":1e-99,"c":"x\\/y"}';
is($json->encode($input),$original,'whitespace normalized; numbers, duplicates, order, escapes retained');
is($text,' { "a": 1.000, "b": "\\u0062", "a": 1e-99, "c": "x\\/y" } ','decoder preserves input scalar');
is([keys %$input],[qw(b a c)],'iteration exposes distinct keys at their final occurrence');
is([map "$_",values %$input],['b','1e-99','x/y'],'values use last occurrence order and decoded characters');
ok(exists $input->{a},'EXISTS sees duplicate key');
is(scalar(%$input),3,'SCALAR counts distinct live keys');
$input->{a}=7;
is($json->encode($input),'{"b":"\\u0062","a":7,"c":"x\\/y"}','STORE collapses duplicates at final position');
is("".delete($input->{b}),'b','DELETE returns last decoded value');
is($json->encode($input),'{"a":7,"c":"x\\/y"}','DELETE removes member');
ok(!exists $input->{b},'deleted key absent');
$input->{b}='new';
is($json->encode($input),'{"a":7,"c":"x\\/y","b":"new"}','reinsertion appends to the live sequence');
is([keys %$input],[qw(a c b)],'reinsertion appends visible iteration key');

my $slots=$json->decode('{"a":1,"b":2,"a":3,"c":4,"b":5}');
my $slot_storage=tied %$slots;
my @each;
while (my ($key,$value)=each %$slots) { push @each,[$key,"$value"] }
is(\@each,[[a=>'3'],[c=>'4'],[b=>'5']],'each skips earlier interleaved duplicates');
delete $slots->{a};
is($json->encode($slots),'{"b":2,"c":4,"b":5}','DELETE unlinks all interleaved occurrences');
is([keys %$slots],[qw(c b)],'iteration skips deleted occurrences');
$slots->{d}=6;
$slots->{e}=7;
is($json->encode($slots),'{"b":2,"c":4,"b":5,"d":6,"e":7}','freed offsets append in logical order');
is(scalar @{$slot_storage->{tokens}},10,'both deleted slots reused');
$slots->{b}=8;
is($json->encode($slots),'{"c":4,"b":8,"d":6,"e":7}','STORE removes earlier duplicate while retaining final position');
my $slot_copy=$slot_storage->_clone;
$slot_copy->{f}=9;
is($json->encode($slot_copy),'{"c":4,"b":8,"d":6,"e":7,"f":9}','clone preserves usable free list');
is($json->encode($slots),'{"c":4,"b":8,"d":6,"e":7}','clone slot reuse does not affect source links');
$slots->{g}=10;
is(scalar @{$slot_storage->{tokens}},10,'source can independently reuse its free list');
%$slots=();
is($json->encode($slots),'{}','CLEAR resets live sequence');
is(scalar %$slots,0,'CLEAR resets distinct key count');
$slots->{z}=undef;
ok(exists($slots->{z}),'null value in first slot remains present');
is($json->encode($slots),'{"z":null}','insertion after CLEAR handles slot zero');
delete $slots->{z};
is($slot_storage->{free},0,'slot zero can head the free list');
$slots->{y}=11;
is($json->encode($slots),'{"y":11}','empty object reuses free slot zero');
is(scalar @{$slot_storage->{tokens}},2,'empty object reuse does not grow arrays');
my $release=$json->decode('{"x":{"old":1},"x":{"last":2}}');
my $old=(tied %$release)->{tokens}[1];
weaken($old);
$release->{x}=3;
ok(!defined($old),'STORE releases removed duplicate subtree references');

for my $token ('900719925474099312345678901234567890','-0','-0.00e+99','0.12345678901234567890123456789','1e-10000','1e99999999999999999999') {
   is($json->encode($json->decode($token)),$token,"number token retained: $token");
}
my $precise=$json->decode('0.12345678901234567890123456789');
is($precise->value->bstr,'12345678901234567890123456789/100000000000000000000000000000','all decimal digits retained');
my $copy=to_rational($precise);
$copy->badd(1);
is($json->encode($precise->value),'0.12345678901234567890123456789','value returns independent numeric copy');
is(to_rational(JSON::PP::true())->bstr,'1','public rational conversion accepts JSON true');
is(to_rational(JSON::PP::false())->bstr,'0','public rational conversion accepts JSON false');
ok(is_number_object($precise) && !is_number_object(1),'numeric object predicate distinguishes native numbers');
is(to_native_number(Math::BigRat->new('1/8')),.125,'public native conversion');
is(to_decimal_string(Math::BigRat->new('1/8')),'0.125','public exact decimal conversion');
ok(estimate_number_digits(Math::BigFloat->new('1e10000'))>=10000,'public digit estimate handles compact exponents');
is(($json->decode('0.1')+$json->decode('0.2'))->bstr,'3/10','numeric overload performs exact decimal arithmetic');
is(($json->decode('0.1')-1)->bstr,'-9/10','numeric overload honors operand order');
is((1-$json->decode('0.1'))->bstr,'9/10','numeric overload honors swapped operand order');
like(dies { $json->decode('1e99999999999999999')->value },qr/max_number_digits/,'huge exponent rejected before expansion');
is(JGraft::JSON->new(max_number_digits=>3,number_overflow=>'native')->decode('1234')->value,1234,'explicit native approximation policy');

for my $case ([Math::BigInt->new('123456789012345678901234567890'),'123456789012345678901234567890'],
   [Math::BigFloat->new('0.00000000000000000000000000000001'),'0.00000000000000000000000000000001'],
   [Math::BigRat->new('1/8'),'0.125'],[Math::BigRat->new('-7/20'),'-0.35']) {
   is($json->encode($case->[0]),$case->[1],'big number encoded exactly');
}
like(dies { $json->encode(Math::BigRat->new('1/3')) },qr/no finite JSON decimal/,'nonterminating rational requires explicit rounding');
like(dies { $json->encode(Math::BigFloat->new('inf')) },qr/non-finite/,'infinity rejected');

for my $case ([q("\\uD800"),0xd800],[q("\\udc00"),0xdc00],[q("\\ud800\\udc00"),0x10000]) {
   is(ord("".$json->decode($case->[0])),$case->[1],'surrogate decoding');
   is($json->encode($json->decode($case->[0])),$case->[0],'surrogate token retained');
}
{
   no warnings 'utf8';
   is("".$json->decode(q("\\ud800x\\udc00")),chr(0xd800).'x'.chr(0xdc00),'non-adjacent escaped surrogates remain separate');
}
is("".$json->decode(q("\\\\u0061")),'\\u0061','escaped backslash does not become a Unicode escape');
my $ascii=JGraft::JSON->new(ascii=>1);
is($ascii->encode(chr(0x10000)),'"\\ud800\\udc00"','ascii output uses UTF-16 pair');
is($ascii->encode($json->decode(q("\\u00E9"))),'"\\u00e9"','changing ascii mode re-encodes string');
my $utf8=JGraft::JSON->new(utf8=>1);
is($utf8->encode($utf8->decode("\"\xc3\xa9\"")),"\"\xc3\xa9\"",'UTF-8 bytes round trip');
like(dies { $utf8->decode("\"\xc0\x80\"") },qr/Invalid UTF-8/,'overlong UTF-8 rejected');
like(dies { $utf8->decode("\"\xed\xa0\x80\"") },qr/Invalid UTF-8/,'surrogate UTF-8 bytes rejected');
like(dies { $utf8->decode("\"\xf4\x90\x80\x80\"") },qr/Invalid UTF-8/,'UTF-8 beyond Unicode rejected');
is(length("".$utf8->decode('"'.('a'x100000).'"')),100000,'long ASCII input avoids regex recursion limits');
is(length("".$utf8->decode('"'.("a\xf0\x90\x80\x80"x20000).'"')),40000,'long mixed UTF-8 input validates in bounded chunks');
is(length("".$utf8->decode('"'.('\\u0061'x20000).'"')),20000,'long escaped string avoids regex recursion limits');
for my $bad ('','01','1.','+1','NaN','[1,]','{"a":1,}','{a:1}','[true false]','"\\x41"',"\"\x01\"",'/*x*/0','0 0') {
   ok(dies { $json->decode($bad) },"strict JSON rejects $bad");
}
like(dies { JGraft::JSON->new(max_depth=>2)->decode('[[[]]]') },qr/max_depth/,'decode depth limit');
like(dies { JGraft::JSON->new(max_depth=>2)->encode([[[]]]) },qr/max_depth/,'encode depth limit');
like(dies { JGraft::JSON->new(max_size=>2)->decode('[0]') },qr/max_size/,'input size limit');
my $cycle=[]; push @$cycle,$cycle;
like(dies { $json->encode($cycle) },qr/cyclic/,'cycles rejected');

my $source=$json->decode('{"a":{"x":1,"x":2},"b":3,"b":4,"s":"\\u0061"}');
my $before=$json->encode($source);
my $exec=JGraft::Exec->new(jgraft=>COPY(9,NODE('a','x')),undo=>1);
$exec->apply($source);
ok($exec->success,'CoW edit of tied hash succeeds') or diag "$exec";
is($json->encode($exec->output),'{"a":{"x":9},"b":3,"b":4,"s":"\\u0061"}','CoW preserves unrelated duplicate members');
is($json->encode($source),$before,'CoW leaves source tokens and ties untouched');
my $cloned=jgexec(JGRAFT(),$source,clone=>1);
is($json->encode($cloned),$before,'deep clone preserves duplicate records');
isnt(refaddr($cloned->{a}),refaddr($source->{a}),'deep clone disconnects nested tied hashes');
my $graft=jgparse($json->decode('["COPY",0.100000000000000000001,["NODE"]]'));
is($json->encode($graft->to_json_data),'["COPY",0.100000000000000000001,["NODE"]]','graft constructor accepts JSON numeric objects');
is($json->encode(jgexec($graft,undef)),'0.100000000000000000001','literal exact number executes');
my $s=$json->decode('"\\u0061"');
is($json->encode(jgexec(COPY(NODE(),NODE()),$s)),'"\\u0061"','unchanged string retains token through execution');
is($json->encode(jgexec(COPY(CONCAT(NODE(),'b'),NODE()),$s)),'"ab"','changed string discards token');
my $wide=$json->decode('"\\ud800\\u0100"');
my $rejected=JGraft::Exec->new(jgraft=>JGRAFT(),codepoint_policy=>'reject');
$rejected->apply($wide);
is($rejected->error,'UNSUPPORTED_GRAFT','wrapped string participates in codepoint policy');
is($json->encode(jgexec(COPY(SLICE(NODE(),1,1),NODE()),$wide)),'"'.chr(0x100).'"','wrapped wide string uses character positions');
is(JGraft::jgformat($json->decode('{"x":1,"x":2}'),indent=>0,wrap=>0),'{"x":1,"x":2}','formatter retains duplicate occurrences');
is(JGraft::jgformat($json->decode('{"x":1,"x":2}'),wrap=>0),'{"x": 1, "x": 2}','indented formatter retains duplicate occurrences');

for my $number (Math::BigInt->new('123456789012345678901234567890'),Math::BigFloat->new('0.1'),Math::BigRat->new('1/10'),$json->decode('0.1')) {
   is(type_mask($number),TYPE_NUMBER,'numeric object recognized');
   ok(is_finite($number),'numeric object finite');
   my $old="$number";
   my $out=jgexec(COPY(ADD(NODE(),Math::BigRat->new('1/10')),NODE()),$number);
   my $expected=to_rational($number)->badd('1/10');
   is($out->bstr,$expected->bstr,'mixed arithmetic uses exact copied rationals');
   is("$number",$old,'arithmetic leaves original object unchanged');
}
is($json->encode(jgexec(COPY(ADD(NODE(0),NODE(1)),NODE()),$json->decode('[0.1,0.2]'))),'0.3','exact arithmetic through JSON tree');
is($json->encode(jgexec(COPY(DIV(NODE(0),NODE(1)),NODE()),[Math::BigInt->new(1),Math::BigInt->new(8)])),'0.125','BigInt division promotes to rational');
is($json->encode(jgexec(COPY(MOD(NODE(0),NODE(1)),NODE()),[Math::BigRat->new('-7/10'),Math::BigRat->new('1/5')])),'0.1','rational modulo uses floor');
is($json->encode(jgexec($json->decode('["COPY",["SLICE",["NODE"],1,2],["NODE"]]'),$json->decode('[0,1,2,3]'))),'[1,2]','wrapped slice bounds iterate without changing their source');
my $inc=$json->decode('1');
my $previous=$inc;
++ $inc;
is("$inc",'2','increment overload works across interpreter versions');
is("$previous",'1','increment leaves original token unchanged');
like(dies { NODE($json->decode('0.99999999999999999999')) },qr/Invalid literal path selector/,'exact fractional literal selector rejected');
my $selector=JGraft::Exec->new(jgraft=>COPY(NODE(ADD($json->decode('0.99999999999999999999'),0)),NODE()));
$selector->apply([0,1]);
is($selector->error,'INVALID_OPERAND','exact fractional selector is not rounded to an integer');
my $no_op=JGraft::Exec->new(jgraft=>JGRAFT(),undo=>1);
$no_op->apply($json->decode('1e99999999999999999'));
is(scalar @{$no_op->undo->actions},0,'undo does not expand unchanged enormous exponent tokens');
like(dies { $json->encode(Math::BigFloat->new('1e1000000000')) },qr/max_number_digits/,'big float expansion bounded before allocation');
my $approx=JGraft::JSON->new(max_number_digits=>3,number_overflow=>'native')->decode('1e-10000');
is($json->encode(jgexec(COPY(ADD(NODE(),1),NODE()),$approx)),'1','explicit native overflow policy avoids exponent expansion');
ok(is_integer($json->decode('10e-1')),'integer exponent token');
ok(!is_integer($json->decode('1e-1')),'fractional exponent token');

# Index storage must not determine visible iteration order.
my $many=$json->decode('{'.join(',',map '"'.sprintf('%05d',$_).'":'.$_,1..2000).'}');
my $storage=tied %$many;
is([keys %$many],[map sprintf('%05d',$_),1..2000],'iteration retains source order across many indexed keys');
for (1..100) { $many->{'00001'}=$_; delete $many->{'00002'}; $many->{'00002'}=$_ }
is(scalar @{$storage->{tokens}},4000,'repeated writes and reinsertion reuse token slots');
my $dups=$json->decode('{'.join(',',map '"x":'.$_,1..2000).'}');
my $limited=JGraft::Exec->new(jgraft=>COPY(5,NODE('x')),limits=>{ops=>100});
$limited->apply($dups);
is($limited->error,'RESOURCE_LIMIT','hidden duplicate occurrences participate in resource accounting');
$dups->{x}=0;
is($json->encode($dups),'{"x":0}','STORE collapses a long duplicate-offset list');

done_testing;
