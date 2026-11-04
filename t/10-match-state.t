use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JSON::PP ();
my $true=JSON::PP::true;
my $false=JSON::PP::false;
sub boolean_case {
   my ($name,$input,$expr,$expected)=@_;
   test_conformance({name=>$name,input=>$input,jgraft=>JGRAFT(COPY($expr,NODE()))->to_json_data,
      output=>$expected? $true : $false});
}

for my $case (
   [undef,NUM(),0], [0,NUM(),1], ['0',NUM(),0], [$false,NUM(),0],
   [undef,BOOL(),0], [$false,BOOL(),1], [0,BOOL(),0], ['false',BOOL(),0],
   ['',STR(),1], [0,STR(),0], [[],ARRAY(),1], [{},ARRAY(),0],
   [2,NUM(1,2),1], [3,NUM(1,2),0], [2,NUM(undef,2),1],
) { boolean_case('scalar and container predicate',@$case) }
for my $case (
   [ARRAY(2),1], [ARRAY(3),0], [IS(ARRAY(2)),1], [IS(ARRAY(1)),0],
   [ARRAY(-1),1], [IS(ARRAY(-1)),0], [ARRAY(-1,2),1], [ARRAY(-3,1),0],
   [ARRAY(2,NONE(EXISTS())),1], [ARRAY(3,NONE(EXISTS())),0],
   [ARRAY(NODE('missing')),0], [ARRAY(LENGTH(),NONE(EXISTS())),1],
   [IS(ARRAY(1,2)),1],
) { boolean_case('array lengths and subset offsets',[1,2],@$case) }
boolean_case('ARRAY subset permits trailing elements under IS',[1,2,3],IS(ARRAY(1,2)),1);
boolean_case('array element matching descends into nested arrays',[[1,2],3],ARRAY(0,[1,2]),1);
boolean_case('one missing array-end node can match',[],IS([NONE(EXISTS())]),1);
boolean_case('cannot match two nodes beyond array end',[],IS([NONE(EXISTS()),NONE(EXISTS())]),0);
boolean_case('missing is distinct from null',{},HAS({a=>undef}),0);
boolean_case('exact match can require an absent property',{},IS({a=>NONE(EXISTS())}),1);
boolean_case('computed bounds are checked in match context',{n=>'bad'},HAS(0,NUM(NODE('n'))),0);
boolean_case('reversed computed bounds fail to match',{lo=>3,hi=>2},HAS(2,NUM(NODE('lo'),NODE('hi'))),0);
boolean_case('ANY catches each operand error',1,ANY(FAIL(),1),1);
boolean_case('NONE treats an operand error as false',1,NONE(FAIL()),1);
boolean_case('ALL fails on an operand error',1,ALL(EXISTS(),FAIL()),0);
boolean_case('invalid operand in SLICE becomes false',{},IS(SLICE('abc',NODE('missing')),''),0);
boolean_case('function result is compared as literal value',{a=>$true},HAS({a=>NOT(EXISTS())}),0);
boolean_case('function boundary resets inherited IS mode',{a=>{b=>1,c=>2}},
   IS({a=>IS(AND(ALL({b=>1}),$true),$true)}),1);
boolean_case('alternate target pattern constructed at original NODE',{a=>{x=>1},b=>{x=>1}},
   IS(NODE('a'),NODE('b')),1);
boolean_case('alternate target match structure uses alternate NODE',{a=>{x=>1}},
   HAS(NODE('a'),{x=>NODE()}),1);
boolean_case('WITH sees sequential bindings and keeps NODE',{x=>1},
   WITH('a',NODE('x'),'b',ADD(TEMP('a'),1),{x=>IS(TEMP('b'),2)}),1);
boolean_case('WITH overlays unwind between ALL operands',{},
   ALL(WITH('x',1,IS(TEMP('x'),1)),NONE(HAS(TEMP('x'),1))),1);
boolean_case('WITH can bind an empty name',{},WITH('',1,HAS(TEMP(''),1)),1);
boolean_case('CURPROP exposes object keys',{a=>1},HAS({a=>IS(CURPROP(),'a')}),1);
boolean_case('CURPROP exposes numeric indices',[7],HAS([IS(CURPROP(),0)]),1);
boolean_case('CURPROP at alternate root is null',{a=>1},HAS(NODE('a'),IS(CURPROP(),undef)),1);
boolean_case('LOCAL rebinding clears CURPROP',{a=>1},HAS({a=>IS(LOCAL(undef,2,CURPROP()),undef)}),1);

test_conformance({name=>'CAPTURE returns an empty object on structural success',input=>1,
   jgraft=>JGRAFT(COPY(CAPTURE(NUM()),NODE()))->to_json_data,output=>{}});
test_conformance({name=>'CAPTURE returns false on mismatch',input=>'1',
   jgraft=>JGRAFT(COPY(CAPTURE(NUM()),NODE()))->to_json_data,output=>$false});
test_conformance({name=>'matching sees deferred array deletions',input=>[1,2],
   jgraft=>JGRAFT(MOVE(1,undef,0,TEMP(CASTSTR(IS([1]))),TEMP('true'),NODE(0)))->to_json_data,
   output=>[1]});

# Simulate an enclosing match's captures until sequence matching can produce
# nonempty capture maps. MATCH/IF must still implement their namespace scopes.
{
   package Test::MatchCaptures;
   our @ISA=('JGraft::Exec');
   sub _run {
      my ($self,$action,$depth)=@_;
      if ($depth==1) {
         local $self->{cap}=[{outer=>1},1];
         return $self->SUPER::_run($action,$depth);
      }
      return $self->SUPER::_run($action,$depth);
   }
}
my $exec=Test::MatchCaptures->new(jgraft=>JGRAFT(
   COPY(CAP(),'before'),MATCH(EXISTS(),COPY(CAP(),'match')),
   COPY(CAP(),'after'),IF(EXISTS(),COPY(CAP(),'yes')),
   IF(NUM(),COPY(CAP(),'wrong'),COPY(CAP(),'else')),
   COPY(CAPTURE(EXISTS()),'captures',CAP(),'inherited')));
$exec->apply({});
ok($exec->success,'capture scope graft succeeds');
is($exec->output,{before=>{outer=>1},match=>{},after=>{outer=>1},yes=>{},
   else=>{outer=>1},captures=>{},inherited=>{outer=>1}},'successful match resets CAP, else inherits CAP, CAPTURE leaves CAP alone');

$exec=JGraft::Exec->new(jgraft=>JGRAFT({expr=>['loop',EXPR('loop')]},COPY(NONE(EXPR('loop')),NODE())),limits=>{depth=>40});
$exec->apply(1);
is($exec->error,'RESOURCE_LIMIT','match guards do not swallow recursive expansion limits');
$exec=JGraft::Exec->new(jgraft=>JGRAFT({v=>2}));
$exec->apply({});
is($exec->error,'UNSUPPORTED_GRAFT','unsupported errors remain fatal');
$exec=JGraft::Exec->new(jgraft=>COPY(ANY(FAIL(),MAP(NODE())),NODE()));
$exec->apply(1);
is($exec->error,'UNSUPPORTED_GRAFT','ANY does not swallow unsupported expressions');
{
   package Test::UnexpectedMatchError;
   our @ISA=('JGraft::Exec');
   sub _expression {
      my ($self,$expr,$depth)=@_;
      die "unexpected evaluation failure\n" if $expr->_name eq 'LENGTH';
      return $self->SUPER::_expression($expr,$depth);
   }
}
$exec=Test::UnexpectedMatchError->new(jgraft=>COPY(ANY(LENGTH()),NODE()));
like(dies { $exec->apply([]) },qr/unexpected evaluation failure/,'unexpected exceptions escape match guards');
my $long='x' x 100000;
my $graft=JGRAFT(COPY(1,'changed'),MATCH({long=>$long}));
my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
$baseline->apply({long=>$long});
$exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>{ops=>$baseline->counters->{ops}*.9});
$exec->apply({long=>$long});
is($exec->error,'RESOURCE_LIMIT','long string comparison contributes to the operation budget');
is($exec->output->{changed},1,'resource failure preserves earlier progress');
is(jgexec($exec->undo,$exec->output),{long=>$long},'undo restores progress before matching resource failure');

# A cursor's path links and missing-node flag also remain available for future
# successor/capture generation, without array ancestors copied at each descent.
$exec=JGraft::Exec->new(jgraft=>MATCH({a=>EXISTS()}));
$exec->apply({});
is($exec->error,'NO_MATCH','MATCH reports mismatch');
$exec->apply({a=>undef});
ok($exec->success,'match state and diagnostic reset when context is reused');
is($exec->error,undef,'recovered match probes leave no stale error');
done_testing;
