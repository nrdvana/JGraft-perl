use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JSON::PP ();

sub sequence_case {
   my ($name,$input,$graft,$output)=@_;
   test_conformance({name=>$name,input=>$input,jgraft=>$graft->to_json_data,output=>$output});
}
my $true=JSON::PP::true;
my $false=JSON::PP::false;
sequence_case('capture names see missing NODE',[1],
   JGRAFT(COPY(CAPTURE([SEQMAX(CASTSTR(EXISTS()),1)]),NODE())),
   {'false'=>{path=>[],ofs=>0,len=>1,lim=>1}});
sequence_case('capture names retain lexical bindings',[1,2],
   JGRAFT(COPY(CAPTURE(WITH('name','group',[SEQMAX(TEMP('name'),1,2)])),NODE())),
   {group=>{path=>[],ofs=>0,len=>2,lim=>2}});
sequence_case('names ignored by boolean matching',[1],
   COPY(IS([SEQMAX(FAIL(),REP())]),NODE()),$true);
sequence_case('ANY suppresses names and nested preferences',[[1,2]],
   COPY(CAPTURE([SEQ(ANY([SEQMAX(FAIL(),REP())]))]),NODE()),{});
sequence_case('REP suppresses nested names and preferences',[[1,2],[3]],
   COPY(CAPTURE(IS([SEQ(REP(2,0,[SEQMAX(FAIL(),REP())]))])),NODE()),{});
sequence_case('a function match has independent capture observability',
   [{g=>{path=>[],ofs=>0,len=>1,lim=>1}}],
   COPY(IS([SEQ(ANY(CAPTURE(HAS([1],[SEQMAX('g',1)]))))]),NODE()),$true);
sequence_case('non-sequence prefix can guard unrelated WITH work',[0],
   JGRAFT({expr=>['loop',EXPR('loop')]},COPY(IS([1,WITH('x',EXPR('loop'),EXISTS())]),NODE())),$false);
sequence_case('non-sequence prefix can guard recursive root aliases',[0],
   JGRAFT({expr=>['loop',EXPR('loop')]},COPY(IS([1,EXPR('loop')]),NODE())),$false);
sequence_case('overlaid WITH restores TEMP between sequence terms',[1,2],
   COPY(LOCAL('x',2,IS([SEQ(WITH('x',1,TEMP('x')),TEMP('x'))])),NODE()),$true);
sequence_case('computed aliases expand at each candidate position',['x'],
   JGRAFT({expr=>['x',SEQ('x')]},COPY(IS([SEQ(REP(0,1)),EXPR(NODE())]),NODE())),$true);
sequence_case('computed aliases select the actual declaration and preference',['a','b'],
   JGRAFT({expr=>['a',SEQMAX('A',REP()),'b',SEQMAX('B',REP())]},
      COPY(CAPTURE(IS([SEQMIN(undef,REP(0,1)),EXPR(NODE())])),NODE())),
   {A=>{path=>[],ofs=>0,len=>2,lim=>2}});
sequence_case('WITH capture names use the candidate starting element',['a','b'],
   COPY(CAPTURE(IS([SEQMIN(undef,REP(0,1)),WITH('name',NODE(),SEQMAX(TEMP('name'),REP()))])),NODE()),
   {a=>{path=>[],ofs=>0,len=>2,lim=>2}});
sequence_case('computed ordinary aliases do not enable sequence semantics',[1],
   JGRAFT({const=>['pick','n'],expr=>['n',NONE()]},COPY(IS([EXPR(CONST('pick'))]),NODE())),$true);
sequence_case('computed ordinary aliases retain a missing end element',[],
   JGRAFT({const=>['pick','n'],expr=>['n',NONE(EXISTS())]},COPY(IS([EXPR(CONST('pick'))]),NODE())),$true);
sequence_case('empty capture can be returned at nonzero offset',[0,1],
   COPY(CAPTURE(ARRAY(1,SEQMAX('empty'))),NODE()),{empty=>{path=>[],ofs=>1,len=>0,lim=>1}});
sequence_case('ARRAY suffix permits a shorter capture with exact inherited structures',[1,2,3],
   COPY(CAPTURE(IS(ARRAY(0,SEQMIN('prefix',REP())))),NODE()),{prefix=>{path=>[],ofs=>0,len=>0,lim=>0}});
sequence_case('observable captures drive later paths and remain immutable',{items=>[1,2]},
   JGRAFT(MATCH({items=>[SEQMAX('g',REP())]},COPY(CAP(),'bounds'),
      COPY(99,NODE('bounds','g','path',0)),COPY(SLICE(CAP('g')),'slice'))),
   {items=>[1,2],bounds=>{g=>{path=>[99],ofs=>0,len=>2,lim=>2}},slice=>[1,2]});

# A zero-width frontier stabilizes; huge finite counts and unbounded counts
# should not require iterating once per repetition.
for my $max (1000000000,-1) {
   my $exec=JGraft::Exec->new(jgraft=>COPY(IS([SEQ(REP(1000000000,$max,SEQ()))]),NODE()),limits=>{ops=>5000});
   $exec->apply([]);
   ok($exec->success,'large zero-width repetition terminates within a small operation budget');
   is($exec->output,$true,'large zero-width repetition can satisfy its minimum');
}
my $graft=JGRAFT(COPY(1,'changed'),MATCH({items=>IS([SEQ(REP())])}));
my $input={items=>[1..60]};
my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
$baseline->apply($input);
my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>{mem=>$baseline->counters->{mem}*.8});
$exec->apply($input);
is($exec->error,'RESOURCE_LIMIT','successor/cursor allocations respect memory limits');
is($exec->output->{changed},1,'resource exhaustion preserves preceding actions');
is(jgexec($exec->undo,$exec->output),$input,'undo restores partial progress after sequence resource exhaustion');
$exec=JGraft::Exec->new(jgraft=>JGRAFT({expr=>['cycle',EXPR('cycle')]},MATCH([SEQ(EXPR('cycle'))])),limits=>{depth=>40});
$exec->apply([]);
is($exec->error,'RESOURCE_LIMIT','recursive macros inside sequences remain bounded');

# Fixture decoding preserves arbitrary object keys and escaped structure, while
# retaining lone surrogates as actual Perl codepoints. Invalid JSON stays fatal.
my $normal_input={'__proto__'=>q({}[]\"),tests=>[1]};
my $normal=JSON::PP->new->encode({name=>'normal',input=>$normal_input,jgraft=>['JGRAFT',{}],output=>$normal_input});
my $outline='{"name":"outline","tests":['.$normal.
   q(,{"name":"unsupported","input":"\ud800","jgraft":["JGRAFT",{}],"output":"\ud800"}]});
my $decoded=Test2AndUtils::_conformance_json($outline);
is($decoded->{tests}[0]{input},$normal_input,'outline preserves arbitrary keys and escaped structural characters');
is(ord($decoded->{tests}[1]{input}),0xd800,'fixture decoding retains lone surrogates');
like(dies { Test2AndUtils::_conformance_json(substr($outline,0,-1)) },qr/conformance JSON/,'truncated outline is rejected');
like(dies { Test2AndUtils::_conformance_json('{"name":false,}') },qr/(?:unexpected|expected|malformed)/i,'ordinary invalid JSON is rejected by decoder');
done_testing;
