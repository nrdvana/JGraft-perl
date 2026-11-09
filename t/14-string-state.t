use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JGraft::CodepointArray;
use Encode ();
use utf8 ();
no warnings 'utf8'; # These tests deliberately construct surrogates/noncharacters.

my $true=JSON::PP::true;
my $false=JSON::PP::false;
for my $text ('',"a\xff\0",'a'.chr(0x100).chr(0xd800).chr(0x1f600)) {
   my $before=$text;
   my $view=JGraft::CodepointArray->new($text);
   isa_ok($view,['JGraft::CodepointArray']);
   is($view->size,length($text),'public packed view derives its codepoint count');
   is([map $view->at($_),0..length($text)-1],[unpack('U*',$text)],'public packed view preserves codepoints');
   my $copy=$view->slice(0,$view->size);
   is([map $copy->at($_),0..$copy->size-1],[unpack('U*',$text)],'slices retain the representation and codepoints');
   is($text,$before,'public construction preserves caller strings');
}
sub matches {
   my ($subject,$pattern,$expected,$name)=@_;
   is(jgexec(COPY(STR($pattern),NODE()),$subject),$expected,$name);
}
matches('a.b','a.b',$true,'literal metacharacters stay literal');
matches('axb','a.b',$false,'literal dot does not become a wildcard');
matches("x\0y","\0y",$true,'literal runs include embedded NULs');
matches('x','',$true,'empty literal is zero width');
matches('',SEQ(START(),END()),$true,'anchors match an empty subject');
matches('abc',SEQ(START(),'b'),$false,'START prevents an unanchored search');
matches('abc',SEQ('bc',END()),$true,'END anchors the absolute end');
matches('abc',SEQ(NUM(98,98),NUM(99,99)),$true,'virtual elements are numeric codepoints');
matches('abc',SEQ('a',NONE('z'),'bc'),$true,'negative assertions do not consume characters');
my $latin=chr(0xe9);
my $wide_latin=$latin; utf8::upgrade($wide_latin);
matches($latin,$wide_latin,$true,'wide pattern can match a byte-valued subject');
matches($wide_latin,$latin,$true,'byte pattern can match a wide subject');
matches($latin,chr(0x100),$false,'wide pattern cannot match an unrelated byte');
matches(chr(0x1f600).'a',SEQ(START(),0x1f600,'a',END()),$true,'astral character occupies one position');
my $ascii='abc'; utf8::upgrade($ascii);
matches($ascii,'bc',$true,'flagged ASCII uses the packed path');

my $context=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()));
$context->apply('');
my @special=(0xd800,0xdfff,0xfdd0,0xfdef,map {($_<<16)+0xfffe,($_<<16)+0xffff} 0..16);
my $text='a'.join('',map chr($_),@special).'z';
my $before=$text;
pos($text)=1;
my @warnings;
my $view;
{
   local $SIG{__WARN__}=sub {push @warnings,@_};
   $view=JGraft::CodepointArray->_new($context,$text,'test');
}
is([unpack('N*',$$view)],[97,@special,122],'every surrogate/noncharacter survives packed conversion');
is(utf8::is_utf8($$view)?1:0,0,'packed buffer has byte semantics');
is($text,$before,'conversion preserves source text');
is(pos($text),1,'conversion preserves caller regex position');
is(\@warnings,[],'known legacy conversion warnings stay local');
for my $cp (@special) {
   matches('a'.chr($cp).'z',SEQ(START(),'a',chr($cp),'z',END()),$true,sprintf('U+%X survives subject and pattern conversion',$cp));
}
is(jgexec(JGRAFT(MATCH({text=>STR(SEQMAX('part',REP(1,-1,CHARS('a'))))},
   COPY(SLICE(CAP('part')),'slice'),COPY(CAP('part'),'bounds'))),{text=>'xxaaa'}),
   {text=>'xxaaa',slice=>'aaa',bounds=>{path=>['text'],ofs=>2,len=>3,lim=>5}},
   'leftmost string captures prefer length and feed SLICE');

for my $policy ('reject','preserve','substitute') {
   my $exec=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>$policy);
   $exec->apply(chr(0xd800));
   is($exec->error,$policy eq 'reject'?'UNSUPPORTED_GRAFT':undef,"$policy policy accepts or rejects surrogate input");
   is($exec->output,chr(0xd800),"$policy policy does not rewrite the stored scalar");
   $exec->apply(chr(0x110000));
   is($exec->error,'UNSUPPORTED_GRAFT',"$policy always rejects codepoints beyond Unicode");
}
my @seen;
my $callback=sub {
   my ($cp,$info)=@_;
   push @seen,[$cp,$info->{index},$info->{kind}];
   return $cp==0xd800?'reject':'preserve';
};
my $exec=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>$callback);
$exec->apply({'key'.chr(0xd800)=>1});
is($exec->error,'UNSUPPORTED_GRAFT','callback may reject problem characters in keys');
is($seen[0],[0xd800,3,'input key'],'callback receives codepoint, character index, and source kind');
$exec=JGraft::Exec->new(jgraft=>COPY(chr(0xfdd0),NODE()),codepoint_policy=>'reject');
$exec->apply('ordinary');
is($exec->error,'UNSUPPORTED_GRAFT','reject policy inspects graft literals without regex execution');
$exec=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>sub {'bogus'});
$exec->apply(chr(0xfdd0));
is($exec->error,'UNSUPPORTED_GRAFT','invalid callback decisions fail explicitly');
my $sentinel=bless {},'StringCallbackError';
$exec=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>sub {die $sentinel});
my $ok=eval {$exec->apply(chr(0xfdd0));1};
is($ok,undef,'callback exceptions propagate');
is($@,$sentinel,'callback exception identity is preserved');

# Substitute deliberately follows the installed Encode, including its legacy
# behavior. Compare raw packed bytes rather than assuming a replacement value.
my $raw;
{
   local $SIG{__WARN__}=sub {};
   $raw=Encode::encode('UTF-32BE',$text);
}
$context=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>'substitute');
$context->apply('');
$view=JGraft::CodepointArray->_new($context,$text,'test');
is($$view,$raw,'substitute leaves the default Encode output intact');
$context=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>sub {$_[0]==0xd800?'substitute':'preserve'});
$context->apply('');
$view=JGraft::CodepointArray->_new($context,$text,'test');
my @expected=(97,@special,122);
$expected[1]=vec($raw,1,32);
is([unpack('N*',$$view)],\@expected,'callback can substitute one codepoint while preserving the others');
@warnings=();
$context=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>sub {warn "policy notification\n"; 'preserve'});
$context->apply('');
{
   local $SIG{__WARN__}=sub {push @warnings,@_};
   JGraft::CodepointArray->_new($context,chr(0xd800),'test');
}
is(\@warnings,["policy notification\n"],'unrelated callback warnings retain their handler');
for my $option (undef,'bad',0,[]) {
   ok(!eval {JGraft::Exec->new(codepoint_policy=>$option);1},'invalid policy configuration is rejected');
}

my $graft=JGRAFT(COPY(1,'changed'),MATCH({text=>STR(SEQ(REP(),'needle'))}));
my $input={text=>chr(0x100)x200};
my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
$baseline->apply($input);
$exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>{mem=>$baseline->counters->{mem}*2});
$exec->apply($input);
is($exec->error,'RESOURCE_LIMIT','packed conversion and search respect memory limits');
is($exec->output->{changed},1,'regex resource failure retains preceding actions');
is(jgexec($exec->undo,$exec->output),$input,'undo restores preceding writes after regex resource failure');
$exec=JGraft::Exec->new(jgraft=>COPY(STR(SEQ(REP(),'z')),NODE()),limits=>{ops=>100});
$exec->apply('a'x100);
is($exec->error,'RESOURCE_LIMIT','successor exploration respects operation limits');
$exec=JGraft::Exec->new(jgraft=>COPY(STR('x'),NODE()));
$exec->apply('x');
is($exec->output,$true,'literal cache is populated');
$exec->apply('y');
is($exec->output,$false,'reused execution contexts reset regex state');
{
   my $graft=JGRAFT(COPY(7,'before'),COPY(LESS(NODE('a'),NODE('b')),'result'));
   my ($short_mem,$long_mem);
   my $input;
   for my $size (16,4096) {
      $input={a=>chr(0x100)x$size,b=>chr(0x101)x$size};
      my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,codepoint_policy=>'substitute');
      $exec->apply($input);
      ok($exec->success,'packed comparison succeeds with scoped views');
      is($exec->output->{result},$true,'packed comparison preserves codepoint ordering');
      is($exec->{scratch_mem},0,'comparison workspace unwinds on success');
      if ($size==16) { $short_mem=$exec->counters->{mem} }
      else { $long_mem=$exec->counters->{mem} }
   }
   is($long_mem,$short_mem,'larger comparison buffers do not accumulate retained mem');
   my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,codepoint_policy=>'substitute',
      limits=>{mem=>$long_mem+8*4096});
   $exec->apply($input);
   is($exec->error,'RESOURCE_LIMIT','simultaneous comparison buffers respect the memory limit');
   like($exec->message,qr/scratch/,'comparison failure identifies live workspace');
   is($exec->output,{%$input,before=>7},'scratch failure retains prior edit and leaves comparison unpublished');
   is(jgexec($exec->undo,$exec->output),$input,'undo restores partial result after comparison scratch failure');
   is($exec->{scratch_mem},0,'comparison failure unwinds all scratch');
   is($input,{a=>chr(0x100)x4096,b=>chr(0x101)x4096},'scratch failure preserves input');
   $exec->apply({a=>'a',b=>'b'});
   ok($exec->success,'comparison context reusable after scratch failure');
}
for my $case (
   ['comparison',COPY(LESS(NODE(),NODE()),NODE())],
   ['subject',COPY(STR('x'),NODE())],
   ['pattern',COPY(STR(chr(0xfdd0)x512),NODE())],
   ['split subject',COPY(SPLIT(',',NODE()),NODE())],
   ['split field',COPY(SPLIT({sep=>',',trim=>' '},NODE()),NODE())],
) {
   my ($kind,$graft)=@$case;
   my $sentinel="exception in $kind view\n";
   my $exec=JGraft::Exec->new(jgraft=>$graft,codepoint_policy=>sub {
      die $sentinel if $_[1]{kind} eq $kind;
      return 'preserve';
   });
   my $error=dies { $exec->apply(chr(0xfdd0)x512) };
   is($error,$sentinel,"$kind callback exception propagates");
   is($exec->{scratch_mem},0,"$kind callback unwinds temporary view reservation");
   $exec->apply('safe');
   ok($exec->success,"$kind callback context reusable after exception");
}
{
   # Small view/preparation buffers must stay covered together while matching
   # calls resource-tracked helpers, as must their caller's cursor frames.
   my $graft=COPY(STR(''),NODE());
   my $input=chr(0x100)x88;
   my $baseline=JGraft::Exec->new(jgraft=>$graft);
   $baseline->apply($input);
   ok($baseline->success,'combined view/preparation baseline succeeds');
   my $limited=JGraft::Exec->new(jgraft=>$graft,limits=>{mem=>$baseline->counters->{mem}});
   $limited->apply($input);
   is($limited->error,'RESOURCE_LIMIT','small subject and preparation buffers combine at their common owner');
   like($limited->message,qr/scratch/,'combined small buffers report scratch exhaustion');
   is($limited->{scratch_mem},0,'combined buffer reservation unwinds');
}
{
   my @mem;
   for my $size (8,2000) {
      my $exec=JGraft::Exec->new(jgraft=>COPY(STR('z'),NODE()));
      $exec->apply('a'x$size);
      ok($exec->success,'unanchored search completes after unsuccessful starts');
      is($exec->output,$false,'all unsuccessful starts remain a mismatch');
      is($exec->{scratch_mem},0,'search releases each start and final invocation');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'repeated unsuccessful starts reuse workspace');
}
{
   my @contexts;
   my $baseline=JGraft::Exec->new(jgraft=>JGRAFT());
   $baseline->apply(chr(0xfdd0)x2);
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT(),codepoint_policy=>sub {
      push @contexts,$_[1];
      return 'preserve';
   });
   $exec->apply(chr(0xfdd0)x2);
   ok($exec->success,'callback may retain context values');
   is(\@contexts,[{index=>0,kind=>'input'},{index=>1,kind=>'input'}],
      'retained callback contexts preserve each occurrence');
   is($exec->counters->{new_obj}-$baseline->counters->{new_obj},2,
      'callback context allocations contribute to object count');
   cmp_ok($exec->counters->{mem},'>',$baseline->counters->{mem},
      'callback contexts remain in cumulative retained memory');
   $contexts[0]{index}=99;
   is($contexts[1]{index},1,'callback contexts are independent values');
   my $calls=0;
   my $limited=JGraft::Exec->new(jgraft=>JGRAFT(),limits=>{new_obj=>0},
      codepoint_policy=>sub {++$calls;return 'preserve'});
   $limited->apply(chr(0xfdd0));
   is($limited->error,'RESOURCE_LIMIT','callback value allocation reserves before invocation');
   is($calls,0,'exhausted object budget does not invoke the callback');
   is($limited->{scratch_mem},0,'callback allocation failure unwinds the scan');
   my $mem_calls=0;
   my $memory_limited=JGraft::Exec->new(jgraft=>JGRAFT(),limits=>{mem=>300},
      codepoint_policy=>sub {++$mem_calls;return 'preserve'});
   $memory_limited->apply(chr(0xfdd0));
   is($memory_limited->error,'RESOURCE_LIMIT','callback context checks the memory budget with the scan live');
   like($memory_limited->message,qr/scratch/,'callback allocation failure identifies active scratch');
   is($mem_calls,0,'insufficient context memory does not invoke callback');
   cmp_ok($memory_limited->counters->{mem},'>',0,'failed callback reservation remains consumed');
   is($memory_limited->{scratch_mem},0,'context memory failure unwinds small scan reservations');
}
done_testing;
