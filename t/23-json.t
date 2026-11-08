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
{
   my $value=$json->decode('{"a":1,"a":2,"b":3}');
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT(),undo=>1);
   $exec->apply(undef);
   my $counts=$exec->counters;
   my $record=$exec->_container($value,1);
   is($exec->counters->{ops},$counts->{ops},'borrowed exact-object identity does not enumerate tied keys');
   is($exec->counters->{new_obj},$counts->{new_obj},'borrowed exact-object metadata does not count as a value allocation');
   is($record->{reserved_slots},undef,'borrowed exact-object slots are not paid construction capacity');
}
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
{
   my $input=$json->decode('{"a":{"untouched":1},"a":{"x":2,"keep":3},"tail":4}');
   my $exec=JGraft::Exec->new(jgraft=>COPY(9,NODE('a','x')),undo=>1);
   $exec->apply($input);
   ok($exec->success,'nested exact-object edit installs cloned ancestors');
   is($json->encode($exec->output),'{"a":{"untouched":1},"a":{"x":9,"keep":3},"tail":4}',
      'ancestor installation preserves earlier duplicate members');
   is($json->encode($input),'{"a":{"untouched":1},"a":{"x":2,"keep":3},"tail":4}',
      'nested duplicate ancestor edit leaves caller representation unchanged');
   is($json->encode(jgexec($exec->undo->to_json_data,$exec->output)),$json->encode($input),
      'serialized undo restores a nested duplicate ancestor edit');
   is($json->encode(jgexec(COPY({x=>7},NODE('a')),$input)),'{"a":{"x":7},"tail":4}',
      'a user assignment still collapses the assigned key duplicates');
}
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

{
   my $object=$json->decode('{"drop":0,"x":1,"x":2,"spelling":"\\u0061"}');
   delete $object->{drop};
   $object->{tail}=3;
   my $expected='{"x":1,"x":2,"spelling":"\\u0061","tail":3}';
   is($json->encode($object),$expected,'encoding follows live links after slot reuse');
   is(JGraft::jgformat($object,indent=>0,wrap=>0),$expected,'compact formatting follows duplicate members and reused slots');
   is(JGraft::jgformat($object,wrap=>0),'{"x": 1, "x": 2, "spelling": "\\u0061", "tail": 3}',
      'indented formatting follows duplicate members and reused slots');
   my (@mem,@ops);
   for my $count (1,10) {
      my $seen=0;
      my $exec=JGraft::Exec->new(jgraft=>COPY(CASTDATE('2024-01-02'),'date'),
         date_format=>sub {
            for (1..$count) { ++$seen if $json->encode($object) eq $expected }
            return 'encoded';
         });
      $exec->apply({});
      ok($exec->success,'encoding exact objects during date export succeeds');
      is($seen,$count,'nested encoding preserves every duplicate and token');
      is($exec->output,{date=>'encoded'},'nested encoding leaves date callback output intact');
      is($exec->{scratch_mem},0,'nested encoding leaves no live execution workspace');
      push @mem,$exec->counters->{mem};
      push @ops,$exec->counters->{ops};
   }
   is($mem[1],$mem[0],'exact-object member traversal does not allocate retained offset lists');
   cmp_ok($ops[1],'>',$ops[0],'each live-member traversal remains charged work');
   is($json->encode($object),$expected,'nested encoding leaves caller-owned storage unchanged');
}

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
my $finite_approx=JGraft::JSON->new(max_number_digits=>3,number_overflow=>'native')->decode('1e100');
cmp_ok(estimate_number_digits($finite_approx),'>=',100,'finite native approximation includes its decimal expansion in conversion estimates');
is(jgexec(COPY(CASTSTR(NODE()),NODE()),$finite_approx),'1'.('0'x100),
   'CASTSTR reserves the finite native approximation rather than just its compact token');
is(jgexec(COPY(LESS(NODE(0),NODE(1)),NODE()),[1e100,Math::BigRat->new('1e101')]),JSON::PP::true,
   'mixed native and rational comparison covers compact native exponents');
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

{
   my @mem;
   for my $size (4,400) {
      my $text='{'.join(',',map {'"x":'.$_} 1..$size).'}';
      my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
      $exec->apply($json->decode($text));
      ok($exec->success,'inspection visits hidden duplicate members');
      is($json->encode($exec->output),$text,'direct inspection preserves every duplicate token');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'exact inspection does not allocate a cumulative offset vector');
   my $input=$json->decode('{"x":{},"x":2}');
   my $hidden=bless {},'UnsupportedHiddenValue';
   (tied %$input)->{tokens}[1]=$hidden;
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
   $exec->apply($input);
   is($exec->error,'UNSUPPORTED_GRAFT','direct member inspection still validates hidden values');
   is(refaddr((tied %$input)->{tokens}[1]),refaddr($hidden),'failed hidden inspection preserves caller storage');
}
{
   my $a=Math::BigInt->new('1'x1000);
   my $b=$a->copy->binc;
   my $input={a=>$a,b=>$b};
   my ($a_before,$b_before)=($a->bstr,$b->bstr);
   my @mem;
   my @objects;
   for my $count (1,10) {
      my @pairs=map {(LESS(NODE('a'),NODE('b')),NODE('result'))} 1..$count;
      my $exec=JGraft::Exec->new(jgraft=>COPY(@pairs));
      $exec->apply($input);
      ok($exec->success,'exact numeric comparisons succeed');
      is($exec->output->{result},JSON::PP::true,'comparison preserves exact ordering');
      is($exec->{scratch_mem},0,'comparison copies unwind with their owner');
      push @mem,$exec->counters->{mem};
      push @objects,$exec->counters->{new_obj};
   }
   is($mem[1],$mem[0],'completed comparison copies do not accumulate retained mem');
   cmp_ok($objects[1],'>',$objects[0],'private numeric copies still count as allocations');
   is([$a->bstr,$b->bstr],[$a_before,$b_before],'comparison leaves caller Math objects unchanged');
   my $graft=JGRAFT(COPY(1,'changed'),COPY(LESS(NODE('a'),NODE('b')),'result'));
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply($input);
   ok($baseline->success,'numeric copy resource baseline succeeds');
   my $limits={mem=>$baseline->counters->{mem}+10000};
   my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
   $limited->apply($input);
   is($limited->error,'RESOURCE_LIMIT','comparison conversion reserves live numeric storage');
   like($limited->message,qr/scratch/,'numeric conversion reports active scratch exhaustion');
   is($limited->output->{changed},1,'numeric scratch failure retains preceding edits');
   ok(!exists $limited->output->{result},'failed comparison does not publish a result');
   is($limited->{scratch_mem},0,'numeric conversion failure unwinds scratch');
   test_conformance({name=>'numeric comparison scratch failure',input=>$input,
      jgraft=>$graft->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}},json=>$json);
   $limited->apply({a=>Math::BigInt->new(2),b=>Math::BigInt->new(3)});
   ok($limited->success,'numeric comparison context reusable after resource failure');
}
{
   my $large=Math::BigInt->new('1'x1000);
   my $small=Math::BigInt->new(2);
   for my $case (
      [ADD(NODE('values')),sub {[$_[0],$_[0]->copy->bneg,1]},'1'],
      [MUL(NODE('values')),sub {[$_[0],0]},'0'],
      [SUB(NODE('values',0),NODE('values',1)),sub {[$_[0],$_[0]]},'0'],
      [DIV(NODE('values',0),NODE('values',1)),sub {[$_[0],$_[0]]},'1'],
      [MOD(NODE('values',0),NODE('values',1)),sub {[$_[0],$_[0]]},'0']) {
      my ($expr,$values,$expected)=@$case;
      my @mem;
      for my $number ($small,$large) {
         my $input={values=>$values->($number)};
         my $before=$json->encode($input);
         my $exec=JGraft::Exec->new(jgraft=>COPY($expr,'result'));
         $exec->apply($input);
         ok($exec->success,'arithmetic consumes private rational operands');
         is($json->encode($exec->output->{result}),$expected,'arithmetic preserves exact cancellation and zero results');
         is($json->encode($input),$before,'arithmetic preserves caller operands and aliases');
         is($exec->{scratch_mem},0,'arithmetic releases operand vectors and conversions');
         push @mem,$exec->counters->{mem};
      }
      is($mem[1],$mem[0],'large private operands do not increase retained mem for the same result');
   }
   my $input={values=>[$large,$large->copy->bneg,1]};
   my $graft=JGRAFT(COPY(1,'changed'),COPY(ADD(NODE('values')),'result'));
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply($input);
   ok($baseline->success,'arithmetic scratch limit baseline succeeds');
   my $limits={mem=>$baseline->counters->{mem}+10000};
   my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
   $limited->apply($input);
   is($limited->error,'RESOURCE_LIMIT','arithmetic conversion must fit while operands are live');
   is($limited->output->{changed},1,'arithmetic resource failure preserves earlier edits');
   ok(!exists($limited->output->{result}),'failed arithmetic does not publish a result');
   is($limited->{scratch_mem},0,'arithmetic resource failure releases its reservation');
   test_conformance({name=>'arithmetic operand scratch failure',input=>$input,
      jgraft=>$graft->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}},json=>$json);
   $limited->apply({values=>[$small,$small->copy->bneg,1]});
   ok($limited->success,'arithmetic context reusable after workspace failure');

   my $nested=JGraft::Exec->new(jgraft=>COPY(ADD(SUB(NODE(),NODE()),1),NODE()));
   $nested->apply($large);
   ok($nested->success,'nested arithmetic retains both expression results');
   is($json->encode($nested->output),'1','nested arithmetic produces the exact result');
   is($nested->{scratch_mem},0,'nested arithmetic restores every owner reservation');
   my $zero=JGraft::Exec->new(jgraft=>COPY(DIV(NODE(),0),NODE()));
   $zero->apply($large);
   is($zero->error,'INVALID_TARGET','division by zero preserves its runtime error');
   is($zero->{scratch_mem},0,'division by zero unwinds converted operands');
}
{
   my @mem;
   for my $size (2,1000) {
      my $exec=JGraft::Exec->new(jgraft=>COPY(ADD(NODE('values')),'result'));
      $exec->apply({values=>[(0)x$size]});
      ok($exec->success,'native arithmetic consumes a borrowed operand array');
      is($exec->output->{result},0,'native operand array sums correctly');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'borrowed native operand vectors do not accumulate retained mem');
   my $graft=JGRAFT(COPY(1,'changed'),COPY(ADD(NODE('values')),'result'));
   my $input={values=>[(0)x1000]};
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply($input);
   my $limits={mem=>$baseline->counters->{mem}+4000};
   my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
   $limited->apply($input);
   is($limited->error,'RESOURCE_LIMIT','native arithmetic reserves its operand vector before copying');
   is($limited->output->{changed},1,'operand-vector failure keeps preceding edits');
   is($limited->{scratch_mem},0,'operand-vector failure releases scratch');
   test_conformance({name=>'native arithmetic vector failure',input=>$input,
      jgraft=>$graft->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}});
   $limited->apply({values=>[0,0]});
   ok($limited->success,'native arithmetic context reusable after vector failure');
}
{
   my $value=Math::BigInt->new('1'x1000);
   my @mem;
   my @objects;
   for my $count (1,2) {
      my $exec=JGraft::Exec->new(jgraft=>COPY(map {(CASTSTR(NODE('value')),'text')} 1..$count));
      $exec->apply({value=>$value});
      ok($exec->success,'large exact numbers format as strings');
      is($exec->output->{text},$value->bstr,'formatting preserves every decimal digit');
      is(type_mask($exec->output->{text}),TYPE_STRING,'formatted result remains string typed');
      is($exec->{scratch_mem},0,'formatting releases its rational and decimal workspaces');
      push @mem,$exec->counters->{mem};
      push @objects,$exec->counters->{new_obj};
   }
   cmp_ok($mem[1]-$mem[0],'>=',length($value->bstr),'each escaping formatted string remains a retained allocation');
   cmp_ok($mem[1]-$mem[0],'<=',8*length($value->bstr),'private formatting copies do not accumulate retained memory');
   cmp_ok($objects[1],'>',$objects[0],'formatting rational copies still count as allocations');
   my $fraction=Math::BigRat->new('1/'.Math::BigInt->new(2)->bpow(300));
   is(jgexec(COPY(CASTSTR(NODE()),NODE()),$fraction),to_decimal_string($fraction),
      'formatting reservation covers decimal places beyond the denominator digit count');
   my $third=JGraft::Exec->new(jgraft=>COPY(CASTSTR(NODE()),NODE()));
   $third->apply(Math::BigRat->new('1/3'));
   is($third->error,'UNSUPPORTED_GRAFT','nonterminating CASTSTR conversion keeps its error');
   is($third->{scratch_mem},0,'failed decimal formatting releases its workspace');
   my $graft=JGRAFT(COPY(1,'changed'),COPY(CASTSTR(NODE('value')),'text'));
   my $input={value=>$value};
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply($input);
   my $limits={mem=>$baseline->counters->{mem}+10000};
   my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
   my $calls=0;
   {
      no warnings 'redefine';
      my $original=\&JGraft::Util::to_decimal_string;
      local *JGraft::Util::to_decimal_string=sub {++$calls; $original->(@_)};
      $limited->apply($input);
   }
   is($limited->error,'RESOURCE_LIMIT','formatting workspace must fit with retained data');
   is($calls,0,'formatting rejects an insufficient budget before decimal expansion');
   is($limited->output->{changed},1,'formatting resource failure preserves earlier edits');
   is($limited->{scratch_mem},0,'formatting resource failure unwinds scratch');
   test_conformance({name=>'numeric formatting scratch failure',input=>$input,
      jgraft=>$graft->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}},json=>$json);
   $limited->apply({value=>Math::BigInt->new(2)});
   ok($limited->success,'formatting context reusable after workspace failure');
}
{
   no warnings 'utf8';
   my ($weak,$active);
   my $sentinel=bless {},'NumericWorkspaceCallbackException';
   my $exec=JGraft::Exec->new(jgraft=>COPY(ADD(1,LENGTH(NODE('text'))),'result'),
      codepoint_policy=>sub {
         if ($_[1]{kind} eq 'expression') { $active=$weak->{scratch_mem}; die $sentinel }
         return 'preserve';
      });
   $weak=$exec; weaken($weak);
   is(refaddr(dies {$exec->apply({text=>chr(0xffff)})}),refaddr($sentinel),
      'arithmetic propagates callback exceptions from operand evaluation');
   cmp_ok($active,'>',0,'arithmetic holds workspace during nested operand evaluation');
   is($exec->{scratch_mem},0,'callback exceptions unwind arithmetic scratch');
}
for my $case (
   [COPY(SLICE(NODE('values'),NODE('index'),NODE('size')),'result'),[20,30]],
   [COPY(NODE('values',NODE('index')),'result'),20]) {
   my @mem;
   for my $objects (0,1) {
      my $input={values=>[10,20,30],index=>$objects?Math::BigInt->new(1):1,
         size=>$objects?Math::BigInt->new(2):2};
      my $before=$json->encode($input);
      my $exec=JGraft::Exec->new(jgraft=>$case->[0]);
      $exec->apply($input);
      ok($exec->success,'numeric object bounds resolve within their consuming operation');
      is($exec->output->{result},$case->[1],'numeric object bounds preserve selector and slice semantics');
      is($json->encode($input),$before,'bound resolution preserves caller data');
      is($exec->{scratch_mem},0,'bound resolution releases rational workspace');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'private numeric bound copies do not increase retained mem');
}
{
   my @mem;
   for my $objects (0,1) {
      my ($min,$max)=$objects?(Math::BigInt->new(1),Math::BigInt->new(-1)):(1,-1);
      my $exec=JGraft::Exec->new(jgraft=>COPY(IS([SEQ(REP($min,$max))]),NODE()));
      $exec->apply([10,20,30]);
      ok($exec->success,'object repetition bounds share the sequence reservation');
      is($exec->output,JSON::PP::true,'object repetition bounds preserve endpoint matching');
      is($exec->{scratch_mem},0,'repetition bounds unwind with their sequence owner');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'private repetition bounds do not accumulate retained mem');
}
{
   my $token='0.125000000000000000001';
   for my $expr (ADD(NODE(),1),LESS(NODE(),1),CASTSTR(NODE())) {
      my $number=$json->decode($token);
      my $exec=JGraft::Exec->new(jgraft=>COPY($expr,NODE()));
      $exec->apply($number);
      ok($exec->success,'cold exact numeric conversion succeeds');
      ok(exists($number->{value}),'exact numeric conversion retains its lazy cache');
      is($number->token,$token,'cache creation preserves caller token spelling');
      is($exec->{scratch_mem},0,'exact numeric conversion releases private copies');
      my $cold=$exec->counters;
      my $cache_id=refaddr($number->{value});
      $exec->apply($number);
      ok($exec->success,'warm exact numeric conversion succeeds');
      cmp_ok($cold->{mem},'>',$exec->counters->{mem},'new persistent rational cache is charged as retained memory');
      cmp_ok($cold->{new_obj},'>',$exec->counters->{new_obj},'creating a rational cache counts as an allocation');
      is(refaddr($number->{value}),$cache_id,'warm conversion reuses its existing cache');
      ok(!defined($JGraft::JSON::Number::EXEC),'numeric accounting context unwinds after apply');
   }
   my $number=$json->decode($token);
   my $rational=to_rational($number);
   is($rational->bstr,'125000000000000000001/1000000000000000000000','utility conversion retains exact token precision');
   my $cached=$number->value;
   ok(exists($number->{value}),'public value accessor still caches its rational');
   my $cache_id=refaddr($number->{value});
   $cached->badd(1);
   is($number->value->bstr,$rational->bstr,'public value returns an independent copy');
   is(to_rational($number)->bstr,$rational->bstr,'utility conversion can reuse an existing cache safely');
   is(refaddr($number->{value}),$cache_id,'conversion preserves an existing cached value');
   for my $token ('1e100','1e-10000') {
      my $approx=JGraft::JSON->new(max_number_digits=>3,number_overflow=>'native')->decode($token);
      my $exec=JGraft::Exec->new(jgraft=>COPY(ADD(NODE(),0),NODE()));
      $exec->apply($approx);
      ok($exec->success,'cached conversion preserves explicit native overflow policy');
      ok(exists($approx->{value}),'native approximation retains its scalar cache');
      my $cold=$exec->counters;
      $exec->apply($approx);
      cmp_ok($cold->{mem},'>',$exec->counters->{mem},'new scalar cache is charged only when created');
      is($cold->{new_obj},$exec->counters->{new_obj},'native cache does not count a rational allocation');
   }
   my $oversized=JGraft::JSON->new(max_number_digits=>3)->decode('1e100');
   my $graft=JGRAFT(COPY(1,'changed'),COPY(ADD(NODE('number'),0),'result'));
   my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   my $input={number=>$oversized};
   $exec->apply($input);
   is($exec->error,'UNSUPPORTED_GRAFT','conversion preserves reject policy');
   is($exec->output->{changed},1,'conversion rejection retains preceding edits');
   ok(!exists($oversized->{value}),'rejected conversion does not install a persistent value');
   is($exec->{scratch_mem},0,'rejected exact conversion unwinds scratch');
   my $undo=jgparse($json->encode($exec->undo->to_json_data));
   is($json->encode(jgexec($undo,$exec->output)),$json->encode($input),
      'serialized undo restores exact tokens without forcing the rejected expansion');
}
{
   my $number=$json->decode('1'x1000);
   $number->value;
   my $graft=JGRAFT(COPY(1,'changed'),COPY(ADD(NODE('number'),0),'result'));
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply({number=>$number});
   ok($baseline->success,'warm numeric-cache allocation baseline succeeds');
   my $limits={mem=>$baseline->counters->{mem}+25000};
   my $fresh=$json->decode('1'x1000);
   my $input={number=>$fresh};
   my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
   $exec->apply($input);
   is($exec->error,'RESOURCE_LIMIT','retained numeric cache must fit alongside private conversion copies');
   ok(!exists($fresh->{value}),'numeric cache reservation fails before installing its value');
   is($exec->output->{changed},1,'numeric cache failure retains earlier edits');
   is($exec->{scratch_mem},0,'numeric cache failure unwinds parsing and operand workspaces');
   ok(!defined($JGraft::JSON::Number::EXEC),'numeric accounting context unwinds after failure');
   test_conformance({name=>'numeric-cache retained allocation failure',input=>$input,
      jgraft=>$graft->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}},json=>$json);
   $exec->apply({number=>$json->decode('2')});
   ok($exec->success,'numeric context reusable after persistent-cache failure');
}
{
   my $source=$json->decode('{'.join(',',map {'"k'.$_.'":'.$_} 1..300).'}');
   my $original=$json->encode($source);
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
   $exec->apply(undef);
   my $retained=$exec->counters->{mem};
   my $copy;
   {
      local $JGraft::JSON::Object::EXEC=$exec;
      $copy=(tied %$source)->_clone;
   }
   is($json->encode($copy),$original,'adapter clone baseline preserves every member');
   my $clone_bytes=$exec->counters->{mem}-$retained;
   $exec->apply(undef);
   $exec->{limits}{mem}=$exec->counters->{mem}+$clone_bytes+16*keys(%$source)-1;
   {
      local $JGraft::JSON::Object::EXEC=$exec;
      is(refaddr(dies {(tied %$source)->_clone}),refaddr($exec),
         'adapter key list must fit alongside retained representation allocation');
   }
   is($exec->error,'RESOURCE_LIMIT','adapter clone reports key-vector exhaustion');
   is($exec->{scratch_mem},0,'adapter clone failure releases key workspace');
   is($json->encode($source),$original,'adapter key-vector failure preserves source links and tokens');
}
{
   my $number=$json->decode('1.000000000000000000001');
   my $earlier=JGraft::Exec->new(jgraft=>COPY(2,NODE()),undo=>1);
   $earlier->apply($number);
   my ($weak,$undo);
   my $outer=JGraft::Exec->new(jgraft=>COPY(CASTDATE('2024-01-02'),NODE()),date_format=>sub {
      my $before=$weak->counters;
      {
         local $weak->{limits}{mem}=0;
         $undo=$earlier->undo;
      }
      is($weak->counters,$before,'generating another context\'s undo consumes no active counters');
      is(refaddr($JGraft::JSON::Number::EXEC),refaddr($weak),'undo generation restores numeric accounting scope');
      my $inner=JGraft::Exec->new(jgraft=>COPY(ADD(NODE(),1),NODE()));
      $inner->apply($json->decode('0.25'));
      ok($inner->success,'nested execution can allocate its own numeric cache');
      is($weak->counters,$before,'nested cache allocation charges its own execution');
      is(refaddr($JGraft::JSON::Number::EXEC),refaddr($weak),'nested execution restores outer numeric accounting');
      return $_[0]->to_iso8601;
   });
   $weak=$outer; weaken($weak);
   $outer->apply(undef);
   ok($outer->success,'outer execution survives nested accounting and undo generation');
   ok(exists($number->{value}),'lazy undo exercised a previously cold numeric cache');
   is($json->encode(jgexec($undo,2)),$number->token,'generated undo retains the exact original number');
   ok(!defined($JGraft::JSON::Number::EXEC),'reentrant accounting scope unwinds completely');
}
{
   my @numbers=(Math::BigInt->new(0),Math::BigInt->new('-'.('1'x2000)),
      Math::BigRat->new('22/7'),Math::BigRat->new('-'.('1'x1000).'/'.('9'x999)),
      Math::BigFloat->new('-12.345'),Math::BigFloat->new('1e1000000000'),
      Math::BigFloat->new('1e-1000000000'));
   my (@spelling,@estimate);
   for my $number (@numbers) {
      my $text=$number->isa('Math::BigFloat') && !$number->isa('Math::BigRat')?$number->bsstr:$number->bstr;
      push @spelling,length($text);
      my $size=length($text);
      if ($text =~ /[eE]([+-]?[0-9]+)\z/) {
         my $exponent=$1;
         $exponent =~ s/^[+-]?0*//;
         $size+=length($exponent)>9?1e100:($exponent||0);
      }
      push @estimate,$size;
   }
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT(),clone=>1);
   my ($error,@sized,@estimated);
   {
      no warnings 'redefine';
      local *Math::BigInt::bstr=sub {die "unexpected integer spelling\n"};
      local *Math::BigRat::bstr=sub {die "unexpected rational spelling\n"};
      local *Math::BigFloat::bsstr=sub {die "unexpected float spelling\n"};
      @sized=map {(JGraft::Util::_number_sizes($_))[0]} @numbers;
      @estimated=map {estimate_number_digits($_)} @numbers;
      $error=dies {$exec->apply(\@numbers)};
   }
   is(\@sized,\@spelling,'numeric storage sizes match compact spelling without constructing it');
   is(\@estimated,\@estimate,'digit estimates preserve exponent magnitude and rational sizes');
   is($error,undef,'inspection and cloning need no decimal spelling buffers');
   ok($exec->success,'large and compact Math objects clone successfully');
   for my $i (0..$#numbers) {
      isnt(refaddr($exec->output->[$i]),refaddr($numbers[$i]),'numeric clone detaches each caller object');
   }
   my $borrowed=JGraft::Exec->new(jgraft=>JGRAFT());
   $borrowed->apply(\@numbers);
   cmp_ok($exec->counters->{ops},'>',$borrowed->counters->{ops},'numeric cloning charges its digit-copy work');
   is($exec->{scratch_mem},0,'numeric sizing and clone calls leave no active workspace');

   my $limited=JGraft::Exec->new(jgraft=>COPY(ADD(NODE(),0),NODE()),limits=>{ops=>1000});
   my $huge=Math::BigFloat->new('1e1000000000');
   {
      no warnings 'redefine';
      local *Math::BigFloat::bsstr=sub {die "unexpected float conversion\n"};
      $error=dies {$limited->apply($huge)};
   }
   is($error,undef,'large-exponent preflight does not require a compact string conversion');
   is($limited->error,'RESOURCE_LIMIT','large exponent is rejected before rational expansion');
   is($limited->{scratch_mem},0,'large-exponent preflight unwinds workspace');
}
for my $token ('1e0000000000000000000000000000000000000002','1E-0000000000000000000000000000000000000002',
   '1e0000000000000000000000000000000000000000','1e9999999999999999999999999999999999999999') {
   my $number=$json->decode($token);
   my $text=$number->token;
   $text =~ /e/ig;
   my $position=pos($text);
   my $before={%$number};
   cmp_ok(estimate_number_digits($number),'>=',length($token),'token sizing handles long zero-padded and enormous exponents');
   is(pos($text),$position,'exponent sizing preserves caller regex position');
   is({%$number},$before,'exponent sizing preserves token state and avoids conversion caches');
}
{
   # Check actual Math entry, rather than deriving a budget from old totals.
   # The final multiplication must not run when its work/storage is unavailable.
   my $input={values=>[map {Math::BigRat->new(('1'x200).$_)} 1..3]};
   my $before=$json->encode($input);
   my $graft=JGRAFT(COPY(1,'changed'),COPY(MUL(NODE('values')),'result'));
   my ($active,@entries);
   my $scope={inside=>0};
   my $original=\&Math::BigRat::bmul;
   {
      no warnings 'redefine';
      local *Math::BigRat::bmul=sub {
         unless ($scope->{inside}) {
            push @entries,{ops=>$active->counters->{ops},new_obj=>$active->counters->{new_obj},
               mem=>$active->counters->{mem}+$active->{scratch_mem}};
         }
         local $scope->{inside}=$scope->{inside}+1;
         return $original->(@_);
      };
      $active=JGraft::Exec->new(jgraft=>$graft,undo=>1);
      $active->apply($input);
      ok($active->success,'growing rational product baseline succeeds');
      cmp_ok(scalar @entries,'>=',3,'baseline reaches every multiplication');
      my $count=@entries;
      my $last=$entries[-1];
      for my $counter (qw(ops mem new_obj)) {
         @entries=();
         my $limits={$counter=>$last->{$counter}-($counter eq 'ops'?.5:1)};
         $active=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
         $active->apply($input);
         is($active->error,'RESOURCE_LIMIT','arithmetic preflight enforces the '.$counter.' budget');
         is(scalar @entries,$count-1,'unavailable '.$counter.' prevents the final multiplication');
         is($active->output->{changed},1,'arithmetic preflight failure preserves earlier edits');
         ok(!exists($active->output->{result}),'arithmetic preflight failure publishes no result');
         is($active->{scratch_mem},0,'arithmetic preflight failure releases accumulator/work buffers');
         is($json->encode($input),$before,'arithmetic preflight failure preserves caller rationals');
         my $counters=$active->counters;
         my $undo=$active->undo;
         is($active->counters,$counters,'building partial arithmetic undo consumes no counters');
         my $serialized=jgparse($json->encode($undo->to_json_data));
         is($json->encode(jgexec($serialized,$active->output)),$before,'serialized undo restores partial arithmetic output');
         # Undo application contains no MUL; subsequent attempts get fresh inputs.
         $active->{limits}{new_obj}=undef if $counter eq 'new_obj';
         $active->apply({values=>[map {Math::BigRat->new($_)} 1..3]});
         ok($active->success,'arithmetic context is reusable after a preflight failure');
         is($active->{scratch_mem},0,'reused arithmetic context has no stale workspace');
      }
      my $move_input={items=>[10,20,30],values=>$input->{values}};
      my $move=MOVE(NODE('items',0),undef,NODE('items',1),NODE('items',MUL(NODE('values'))));
      @entries=();
      $active=JGraft::Exec->new(jgraft=>$move,undo=>1);
      $active->apply($move_input);
      is($active->error,'INVALID_TARGET','MOVE arithmetic baseline reaches its out-of-range selector');
      my $move_count=@entries;
      my $limits={ops=>$entries[-1]{ops}-.5};
      @entries=();
      $active=JGraft::Exec->new(jgraft=>$move,undo=>1,limits=>$limits);
      $active->apply($move_input);
      is($active->error,'RESOURCE_LIMIT','MOVE propagates arithmetic preflight exhaustion');
      is(scalar @entries,$move_count-1,'MOVE does not calculate an unreserved final product');
      is($active->output->{items},[20,30],'MOVE finalizes earlier deferred deletion after arithmetic failure');
      is($move_input->{items},[10,20,30],'arithmetic failure preserves MOVE input');
      is($active->{scratch_mem},0,'MOVE releases both arithmetic and pending workspace');
      my $serialized=jgparse($json->encode($active->undo->to_json_data));
      is($json->encode(jgexec($serialized,$active->output)),$json->encode($move_input),
         'serialized undo restores MOVE after arithmetic preflight failure');
      test_conformance({name=>'MOVE arithmetic preflight failure',input=>$move_input,
         jgraft=>$move->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}},json=>$json);
   }
}
{
   my @pairs=(['7/11','-13/17'],['-7/11','13/17'],['-7/11','-13/17'],['7/11','13/17'],
      [('1'x90).'/'.('9'x89),('2'x87).'/'.('7'x86)],['123456789','1/123456789']);
   my @ops=(['add',sub {ADD(NODE(0),NODE(1))},sub {$_[0]+$_[1]}],
      ['sub',sub {SUB(NODE(0),NODE(1))},sub {$_[0]-$_[1]}],
      ['mul',sub {MUL(NODE(0),NODE(1))},sub {$_[0]*$_[1]}],
      ['div',sub {DIV(NODE(0),NODE(1))},sub {$_[0]/$_[1]}],
      ['mod',sub {MOD(NODE(0),NODE(1))},sub {my $q=($_[0]/$_[1])->bfloor; $_[0]-$q*$_[1]}]);
   for my $op (@ops) {
      for my $pair (@pairs) {
         my ($a,$b)=map {Math::BigRat->new($_)} @$pair;
         my $before=[$a->bstr,$b->bstr];
         my $expected=$op->[2]->($a,$b);
         my $graft=COPY($op->[1]->(),NODE());
         my $native=JGraft::Exec->new(jgraft=>$graft);
         $native->apply([1,1]);
         my $exec=JGraft::Exec->new(jgraft=>$graft);
         $exec->apply([$a,$b]);
         ok($exec->success,'bounded '.$op->[0].' handles rational signs and denominator growth');
         is(type_mask($exec->output),TYPE_NUMBER,'bounded exact arithmetic returns a numeric value');
         is($exec->output->bstr,$expected->bstr,'bounded arithmetic preserves exact rational value');
         cmp_ok($exec->counters->{mem}-$native->counters->{mem},'>=',8*length($expected->bstr),
            'escaping rational has sufficient retained allocation allowance');
         is([$a->bstr,$b->bstr],$before,'bounded arithmetic leaves caller operands unchanged');
         is($exec->{scratch_mem},0,'bounded arithmetic releases all temporary work');
      }
   }
   my @values=map {Math::BigRat->new($_)} ('7/11','-13/17','19/23','-29/31');
   for my $case ([ADD(NODE()),sub {my $v=Math::BigRat->new(0); $v+=$_ for @values; $v}],
      [MUL(NODE()),sub {my $v=Math::BigRat->new(1); $v*=$_ for @values; $v}]) {
      my $exec=JGraft::Exec->new(jgraft=>COPY($case->[0],NODE()));
      $exec->apply(\@values);
      ok($exec->success,'n-ary arithmetic grows a private accumulator');
      is($exec->output->bstr,$case->[1]->()->bstr,'accumulator growth preserves the exact folded result');
      is($exec->{scratch_mem},0,'final accumulator is retained while its workspace unwinds');
   }
}
{
   local $Math::BigRat::downgrade='Math::BigInt';
   for my $case ([ADD(NODE(),1,2),'6'],[MUL(NODE(),2,3),'18']) {
      my $input=Math::BigRat->new(3);
      my $exec=JGraft::Exec->new(jgraft=>COPY($case->[0],NODE()));
      $exec->apply($input);
      ok($exec->success,'accumulator bounds tolerate library integer downgrades');
      is($exec->output->bstr,$case->[1],'integer downgrade preserves the arithmetic result');
      is($input->bstr,'3','library downgrade does not mutate caller operands');
      is($exec->{scratch_mem},0,'downgraded accumulator releases its workspace');
   }
}
done_testing;
