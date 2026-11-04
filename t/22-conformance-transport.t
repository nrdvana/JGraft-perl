use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JGraft::Util qw(type_mask TYPE_NUMBER TYPE_STRING);
use JSON::PP ();
use utf8 ();

for my $case (
   [q("\ud800"),[0xd800]],
   [q("\udc00"),[0xdc00]],
   [q("\ud800x\udc00"),[0xd800,120,0xdc00]],
   [q("\ud800\udc00"),[0x10000]],
   [q("\ud800\ud83d\ude00"),[0xd800,0x1f600]],
   [JSON::PP->new->allow_nonref->encode("\\ud800"),[92,117,100,56,48,48]],
   [JSON::PP->new->allow_nonref->encode("\0\n\t\\\"/"),[0,10,9,92,34,47]],
) {
   no warnings 'utf8';
   my $value=Test2AndUtils::_conformance_json($case->[0]);
   is([map ord($_),split //,$value],$case->[1],'fixture strings retain exactly their intended codepoints');
   my $round=Test2AndUtils::_conformance_json(JSON::PP->new->allow_nonref->encode($value));
   is([map ord($_),split //,$round],$case->[1],'encoded undo strings round trip losslessly');
}
my $wide=chr(0x1f600);
my $bytes='"'.$wide.'"';
utf8::encode($bytes);
is(Test2AndUtils::_conformance_json($bytes),$wide,'raw UTF-8 is decoded to Perl characters');
for my $token ('0','-0','1e20','100000000000000000000','-2.5e-7') {
   my $value=Test2AndUtils::_conformance_json($token);
   is(type_mask($value),TYPE_NUMBER,"numeric token $token remains a number");
   is($value,0+$token,'numeric value is preserved within host precision');
   my $string=Test2AndUtils::_conformance_json('"'.$token.'"');
   is(type_mask($string),TYPE_STRING,'the quoted spelling remains a string');
}
ok(Test2AndUtils::_conformance_same(1e20,0+'100000000000000000000'),'conformance comparison accepts equal numeric representations');
ok(!Test2AndUtils::_conformance_same(1,'1'),'conformance comparison distinguishes strings from numbers');
ok(!Test2AndUtils::_conformance_same(JSON::PP::true(),1),'conformance comparison distinguishes booleans from numbers');
ok(!Test2AndUtils::_conformance_same([1,2],[2,1]),'conformance comparison preserves array order');
for my $invalid ('','[1,]','{"x":1,}','01','1.','1e','true false','{"x" 1}',
   '"bad'.chr(1).'"','"\\q"','"\\uFFFFF', '["unterminated', '"'.chr(0xff).'"') {
   ok(!eval {Test2AndUtils::_conformance_json($invalid);1},'invalid fixture JSON is rejected');
}

for my $token ('1e-400','-1e-999999') {
   my $exec=JGraft::Exec->new(jgraft=>COPY(CASTNUM(),NODE()));
   $exec->apply($token);
   is($exec->error,'UNSUPPORTED_GRAFT','CASTNUM reports nonzero underflow rather than silently producing zero');
}
for my $token ('0e-999999','-0.000e-999999') {
   is(jgexec(COPY(CASTNUM(),NODE()),$token),0,'zero mantissas are valid even with extreme exponents');
}
for my $pair ([1e21,'1000000000000000000000'],[1.25e21,'1250000000000000000000'],
   [-1e21,'-1000000000000000000000'],[1e100,'1'.('0'x100)]) {
   is(jgexec(COPY(CASTSTR(),NODE()),$pair->[0]),$pair->[1],'CASTSTR expands integer exponent notation to decimal digits');
}
# Native integer scalars must not pass through floating point during formatting.
my $unsigned_max = ~0;
for my $value ($unsigned_max>>1,$unsigned_max) {
   my $native=JSON::PP->new->allow_nonref->encode($value);
   is(jgexec(COPY(CASTSTR(),NODE()),$value),$native,'CASTSTR retains the exact native integer spelling');
}
like(dies {SLICE('abc')},qr/SLICE configuration must be an object/,'literal SLICE values without offsets are invalid grafts');
is(jgexec(COPY(SLICE(NODE('cfg')),NODE()),{cfg=>{path=>['data'],ofs=>1,len=>1},data=>[1,2,3]}),[2],
   'the one-operand SLICE form accepts runtime configuration objects');
done_testing;
