use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JGraft::_String;
use Encode ();
use utf8 ();
no warnings 'utf8'; # These tests deliberately construct surrogates/noncharacters.

my $true=JSON::PP::true;
my $false=JSON::PP::false;
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
   $view=JGraft::_String->_new($context,$text,'test');
}
is([unpack('N*',$view->{buffer})],[97,@special,122],'every surrogate/noncharacter survives packed conversion');
is(utf8::is_utf8($view->{buffer})?1:0,0,'packed buffer has byte semantics');
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
$view=JGraft::_String->_new($context,$text,'test');
is($view->{buffer},$raw,'substitute leaves the default Encode output intact');
$context=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>sub {$_[0]==0xd800?'substitute':'preserve'});
$context->apply('');
$view=JGraft::_String->_new($context,$text,'test');
my @expected=(97,@special,122);
$expected[1]=vec($raw,1,32);
is([unpack('N*',$view->{buffer})],\@expected,'callback can substitute one codepoint while preserving the others');
@warnings=();
$context=JGraft::Exec->new(jgraft=>COPY(NODE(),NODE()),codepoint_policy=>sub {warn "policy notification\n"; 'preserve'});
$context->apply('');
{
   local $SIG{__WARN__}=sub {push @warnings,@_};
   JGraft::_String->_new($context,chr(0xd800),'test');
}
is(\@warnings,["policy notification\n"],'unrelated callback warnings retain their handler');
for my $option (undef,'bad',0,[]) {
   ok(!eval {JGraft::Exec->new(codepoint_policy=>$option);1},'invalid policy configuration is rejected');
}

my $graft=JGRAFT(COPY(1,'changed'),MATCH({text=>STR(SEQ(REP(),'needle'))}));
my $input={text=>chr(0x100)x200};
my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
$baseline->apply($input);
$exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>{mem=>$baseline->counters->{mem}*.8});
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
done_testing;
