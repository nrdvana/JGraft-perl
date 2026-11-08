use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors);
use JGraft::Exec;
use JSON::PP ();
my $false=JSON::PP::false;
my $true=JSON::PP::true;
my @cases;
sub example {
   my ($name,$input,$graft,$output)=@_;
   push @cases,{name=>$name,input=>$input,jgraft=>$graft->to_json_data,output=>$output};
}
sub failure {
   my ($name,$input,$graft,$code)=@_;
   push @cases,{name=>$name,input=>$input,jgraft=>$graft->to_json_data,errors=>{$code=>1}};
}

example('EXPR supplies COPY destination',{},
   JGRAFT({expr=>['target',NODE('result')]},COPY(7,EXPR('target'))),{result=>7});
example('EXPR supplies MOVE endpoints',{a=>{x=>1}},
   JGRAFT({expr=>['source',NODE('a'),'tmp',TEMP(0),'target',NODE('b')]},
      MOVE(EXPR('source'),EXPR('tmp'),EXPR('tmp'),EXPR('target'))),{b=>{x=>1}});
example('EXPR supplies AT reference',{a=>{x=>1}},
   JGRAFT({expr=>['target',NODE('a')]},AT(EXPR('target'),COPY(2,'x'))),{a=>{x=>2}});
example('EXPR aliases another EXPR',{},
   JGRAFT({expr=>['first',EXPR('second'),'second',NODE('x')]},COPY(1,EXPR('first'))),{x=>1});
example('EXPR name evaluated in calling action',{},
   JGRAFT({expr=>['target',TEMP('value')]},
      COPY('target',TEMP('name'),7,EXPR(TEMP('name')),TEMP('value'),'result')),{result=>7});
example('inherited path macro observes inner constants',{},
   JGRAFT({const=>['key','outer'],expr=>['target',NODE(CONST('key'))]},
      JGRAFT({const=>['key','inner']},COPY(1,EXPR('target'))),
      COPY(2,EXPR('target'))),{inner=>1,outer=>2});
example('path macro respects AT current node',{a=>{},b=>{}},
   JGRAFT({expr=>['target',NODE('x')]},
      AT('a',COPY(1,EXPR('target'))),AT('b',COPY(2,EXPR('target')))),{a=>{x=>1},b=>{x=>2}});
example('path macro can supply root reference',{x=>1},
   JGRAFT({expr=>['root',NODE()]},COPY(2,EXPR('root'))),2);
example('path macro can supply a half-index MOVE target',[1,2],
   JGRAFT({expr=>['target',NODE(-.5)]},MOVE(1,EXPR('target'))),[2,1]);
example('path macro can expand a selector array',{a=>[{x=>1}]},
   JGRAFT({expr=>['target',NODE(['a',0,'x'])]},COPY(2,EXPR('target'))),{a=>[{x=>2}]});
example('value macro expands inside a NODE path',{a=>[{x=>1}]},
   JGRAFT({expr=>['path',['a',0,'x']]},COPY(2,NODE(EXPR('path')))),{a=>[{x=>2}]});
example('macro returning a literal expression-looking array remains data',{},
   JGRAFT({expr=>['data',['NODE','missing']]},COPY(EXPR('data'),'out')),{out=>['NODE','missing']});
example('unused recursive macro stays unevaluated',{},
   JGRAFT({expr=>['cycle',EXPR('cycle')]}),{});

example('declaration phases and scope restoration',{},
   JGRAFT({const=>['x','outer'],expr=>['stash',STASH('v'),'read',CONST('x')]},
      COPY('parent stash',STASH('v')),
      JGRAFT({const=>['x','inner','saved',EXPR('stash'),'earlier',EXPR('read')],
              expr=>['read','replacement']},
         COPY({saved=>CONST('saved'),earlier=>CONST('earlier'),now=>EXPR('read'),stash=>STASH()},'inner')),
      COPY({x=>CONST('x'),read=>EXPR('read'),stash=>STASH()},'outer')),
   {inner=>{saved=>'parent stash',earlier=>'inner',now=>'replacement',stash=>{}},
    outer=>{x=>'outer',read=>'outer',stash=>{v=>'parent stash'}}});
example('sequential constants and namespace snapshots',{},
   JGRAFT({const=>[0,1,'0',ADD(CONST(0),1),'before',CONST()]},COPY(CONST(),NODE())),
   {'0'=>2,before=>{'0'=>2}});
example('CONST snapshots data before root edits',{x=>{n=>1}},
   JGRAFT({const=>['saved',NODE('x')]},COPY(2,NODE('x','n')),COPY(CONST('saved'),'saved')),
   {x=>{n=>2},saved=>{n=>1}});
example('TEMP visible within one action',{},
   COPY({n=>1},TEMP(0),TEMP('0'),'first',2,TEMP(0,'n'),TEMP(0),'second'),
   {first=>{n=>1},second=>{n=>2}});
example('STASH root copy stays stable',{},
   JGRAFT(COPY(1,STASH('x')),COPY(STASH(),'before'),COPY(2,STASH('x')),COPY(STASH(),'after')),
   {before=>{x=>1},after=>{x=>2}});
example('CONST STASH and EXPR names independent',{},
   JGRAFT({const=>[0,1],expr=>[0,2]},COPY(3,STASH(0)),
      COPY({constant=>CONST('0'),expression=>EXPR('0'),stash=>STASH('0')},NODE())),
   {constant=>1,expression=>2,stash=>3});
example('CAP starts empty outside matching',{},COPY(CAP(),NODE()),{});
example('inner JGRAFT also starts without captures',{},JGRAFT(JGRAFT(COPY(CAP(),NODE()))),{});
example('custom metadata is not executed',{},JGRAFT({'#project'=>[EXPR('missing')->to_json_data]}),{});

for my $name ('',0,-1,'1.5','__proto__','constructor','a.b',"\x{96ea}") {
   my $label=$name;
   example('flat constant and expression names: '.$label,{},
      JGRAFT({const=>[$name,7],expr=>[$name,CONST($name)]},COPY(EXPR($name),'out')),{out=>7});
}
for my $body (CONST('x'),CAP(),CAP('x')) {
   failure('path macro cannot write '.$body->name,{},
      JGRAFT({const=>['x',1],expr=>['target',$body]},COPY(2,EXPR('target'))),'INVALID_OPERAND');
}
for my $body (STASH('x'),TEMP(0),CONST('x'),CAP()) {
   failure('AT alias must resolve to NODE: '.$body->name,{},
      JGRAFT({expr=>['target',$body]},AT(EXPR('target'))),'INVALID_OPERAND');
}
for my $body (LENGTH(),{},[],undef) {
   failure('path alias must expand to a reference',{},
      JGRAFT({expr=>['target',$body]},COPY(1,EXPR('target'))),'INVALID_OPERAND');
}
for my $body (STASH(),TEMP([])) {
   failure('macro cannot overwrite namespace root: '.$body->name,{},
      JGRAFT({expr=>['target',$body]},COPY(1,EXPR('target'))),'INVALID_GRAFT');
}
failure('TEMP resets between sibling actions',{},
   JGRAFT(COPY(7,TEMP('x')),COPY(TEMP('x'),'out')),'INVALID_TARGET');
failure('TEMP does not leak into child action',{},
   JGRAFT(COPY(7,TEMP('x')),AT(NODE(),COPY(TEMP('x'),'out'))),'INVALID_TARGET');
failure('EXPR observes invoking action TEMP',{},
   JGRAFT({expr=>['read',TEMP('x')]},COPY(7,TEMP('x')),COPY(EXPR('read'),'out')),'INVALID_TARGET');
failure('literal TEMP empty expansion is invalid graft',{},COPY(TEMP([]),NODE()),'INVALID_GRAFT');
failure('computed TEMP empty expansion is invalid operand',{path=>[]},COPY(TEMP(NODE('path')),NODE()),'INVALID_OPERAND');
failure('missing capture is invalid target',{},COPY(CAP('missing'),NODE()),'INVALID_TARGET');
failure('new expression declarations follow constant evaluation',{},
   JGRAFT({const=>['x',EXPR('new')],expr=>['new',1]}),'INVALID_TARGET');
failure('unsupported version checked before initializer',{},
   JGRAFT({v=>2,const=>['bad',NODE('missing')]}),'UNSUPPORTED_GRAFT');
failure('path alias cannot use a missing definition',{},COPY(1,EXPR('missing')),'INVALID_TARGET');
failure('computed EXPR name cannot expand arrays',{name=>['target']},
   JGRAFT({expr=>['target',1]},COPY(EXPR(NODE('name')),NODE())),'INVALID_OPERAND');
failure('read cannot autovivify a reference',{},COPY(NODE('missing','x'),NODE()),'INVALID_TARGET');
failure('namespace first selector must be an integer',{},MOVE(undef,STASH(.5)),'INVALID_GRAFT');
for my $selector (undef,$true,1.5,{},[[0]]) {
   failure('computed invalid selector',{selector=>$selector},COPY(NODE(NODE('selector')),NODE()),'INVALID_OPERAND');
}
for my $target ([0,{}],[$false,{}],['0',[]]) {
   failure('selector cannot change container type',{selector=>$target->[0],target=>$target->[1]},
      COPY(NODE('target',NODE('selector')),NODE()),'INVALID_TARGET');
}

test_conformance({name=>'Namespaces and references',tests=>\@cases});

# CAP reads use the same reference resolver when the match engine supplies
# capture metadata. Populating that namespace remains the matching engine's job.
my $captures={'0'=>{path=>['list',0],ofs=>1,len=>2,lim=>3}};
my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
$exec->apply({});
$exec->{cap}=[$captures,1];
is($exec->_eval(CAP(0,'path'),1),['list',0],'CAP accepts numeric capture names');
is($exec->_eval(CAP('0','len'),1),2,'CAP reads capture fields');
is($exec->_eval(CAP(),1),$captures,'CAP root references all capture metadata');

# Recursion through a path alias must have the same execution limits as values.
$exec=JGraft::Exec->new(jgraft=>JGRAFT({expr=>['cycle',EXPR('cycle')]},COPY(1,EXPR('cycle'))),limits=>{depth=>40});
$exec->apply({});
is($exec->error,'RESOURCE_LIMIT','path macro recursion is bounded');
isa_ok($exec->diagnostic->{expression},['JGraft::Expr::EXPR']);

# Reusing a parsed graft or execution context never reuses namespace bindings.
$exec=JGraft::Exec->new(jgraft=>JGRAFT({const=>['saved',NODE()]},COPY(CONST('saved'),NODE())));
is([$exec->apply({n=>1})],[{n=>1}],'first application initializes its constants');
is([$exec->apply({n=>2})],[{n=>2}],'second application initializes fresh constants');
{
   my @bindings=map {('k'.$_=>$_)} 1..300;
   my $scope=LOCAL(@bindings,LOCAL('k300',999,TEMP('k300')));
   my $graft=JGRAFT(COPY(1,'changed'),COPY($scope,'result'));
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply({});
   ok($baseline->success,'large LOCAL namespace copies preserve nested bindings');
   is($baseline->output->{result},999,'inner LOCAL reads its overridden binding');
   is($baseline->{scratch_mem},0,'LOCAL copy workspace unwinds after success');
   my $limits={mem=>$baseline->counters->{mem}};
   my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
   $limited->apply({});
   is($limited->error,'RESOURCE_LIMIT','namespace copies check live copy workspace with retained tables');
   is($limited->output->{changed},1,'namespace copy exhaustion keeps preceding edits');
   ok(!exists($limited->output->{result}),'namespace copy exhaustion publishes no expression result');
   is($limited->{scratch_mem},0,'namespace copy failure unwinds its scratch');
   test_conformance({name=>'namespace copy scratch exhaustion',input=>{},
      jgraft=>$graft->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}});
   $limited->{limits}{mem}=undef;
   $limited->apply({reused=>1});
   ok($limited->success,'namespace context rebuilds its bindings after resource failure');
   is($limited->{scratch_mem},0,'namespace context reuse has no stale reservation');

   my @mem;
   for my $size (2,100) {
      my $exec=JGraft::Exec->new(jgraft=>COPY(LOCAL(map({('k'.$_=>$_)} 1..$size),0),'result'));
      $exec->apply({});
      ok($exec->success,'LOCAL constructs a retained binding table');
      push @mem,$exec->counters->{mem};
   }
   cmp_ok($mem[1]-$mem[0],'>=',64*(100-2),'LOCAL bindings pay for retained property slots');
}
{
   my $source={map {('k'.$_=>$_)} 1..300};
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
   $exec->apply(undef);
   my $before=$exec->counters;
   my $bytes=80+32*keys %$source;
   $exec->{limits}{mem}=$before->{mem}+$bytes-1;
   my $error=dies {$exec->_copy_hash($source,scalar(keys %$source)+1)};
   is(Scalar::Util::refaddr($error),Scalar::Util::refaddr($exec),'copy allocator preflights full key/value workspace');
   is($exec->counters->{new_obj},$before->{new_obj},'copy workspace failure precedes retained allocation');
   is($exec->{scratch_mem},0,'copy allocator restores its caller reservation');
   $exec->{limits}{mem}=undef;
   my $copy=$exec->_copy_hash($source,scalar(keys %$source)+1);
   is($copy,$source,'copy allocator fills the new table without modifying its source');
   my $mem=$exec->counters->{mem};
   $exec->_set_member($copy,'x',1);
   cmp_ok($exec->counters->{mem}-$mem,'<',64,'filling paid extra capacity does not buy the slot again');
   ok(!exists($source->{x}),'copied namespace edits remain isolated from the source');
}
done_testing;
