use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JGraft::Util qw(:types type_mask is_finite is_integer);
use Scalar::Util qw(refaddr blessed);
use JSON::PP ();
my $json=JSON::PP->new->canonical->allow_nonref;

my $input={a=>{x=>1},untouched=>[2]};
my $out=jgexec(COPY(3,NODE('a','x')),$input);
is($input,{a=>{x=>1},untouched=>[2]},'COPY preserves input');
is($out,{a=>{x=>3},untouched=>[2]},'COPY writes leaf');
isnt(refaddr($out),refaddr($input),'root cloned');
isnt(refaddr($out->{a}),refaddr($input->{a}),'ancestor cloned');
is(refaddr($out->{untouched}),refaddr($input->{untouched}),'untouched sibling shared');

my $shared={x=>1};
$out=COPY(2,NODE('a','x'))->exec({a=>$shared,b=>$shared});
is($out,{a=>{x=>2},b=>{x=>1}},'input aliases behave as independent trees');
$out=JGRAFT(COPY({nested=>{x=>1}},'a'),COPY(NODE('a'),'b'),
   COPY(2,NODE('a','nested','x'),3,NODE('b','nested','y')))->exec({});
is($out,{a=>{nested=>{x=>2}},b=>{nested=>{x=>1,y=>3}}},'copies of owned descendants detach on both branches');

my $simple=JGraft::Exec->new(jgraft=>COPY(1,NODE('a','x')));
$simple->apply($input);
my $multiple=JGraft::Exec->new(jgraft=>COPY(1,NODE('a','x'),2,NODE('a','y'),3,NODE('a','z')));
$multiple->apply($input);
is($multiple->counters->{new_obj},$simple->counters->{new_obj},'repeated scalar writes reuse owned ancestors');

my $cloned=jgexec(JGRAFT(),{a=>$shared,b=>$shared},clone=>1);
isnt(refaddr($cloned->{a}),refaddr($shared),'clone disconnects unchanged subtrees');
isnt(refaddr($cloned->{a}),refaddr($cloned->{b}),'clone separates repeated occurrences');

$out=jgexec(MOVE(NODE('a',0),NODE('a',1.5),'a','b'),{a=>[1,2]});
is($out,{b=>[2,1]},'deferred metadata follows moved array');
my $exec=JGraft::Exec->new(jgraft=>MOVE(0,undef,1,undef,0,undef),undo=>1);
my $original=[1,2,3];
my @result=$exec->apply($original);
is(\@result,[],'expected failure returns empty list');
is($exec->error,'INVALID_TARGET','deleted element cannot be read');
is($exec->output,[3],'successful removals finalized on failure');
is($original,[1,2,3],'failure preserves original array');
is(jgexec($exec->undo,$exec->output),$original,'undo restores partial output');
ok(blessed($exec->diagnostic->{action}),'failure includes action');

$exec=JGraft::Exec->new(jgraft=>COPY(undef,NODE()),undo=>1);
@result=$exec->apply($input);
is(scalar @result,1,'null success returns one element');
ok($exec->success,'null result is successful');
is($exec->error,undef,'null success has no error');
is(jgexec($exec->undo,$exec->output),$input,'undo restores full replacement');
is(jgexec(COPY(0,NODE()),1),0,'wrapper returns false numeric output');
is(jgexec(COPY(undef,NODE()),1),undef,'wrapper returns null output');
my $err=dies { jgexec(COPY(NODE('missing'),NODE()),{}) };
isa_ok($err,['JGraft::Exec']);
like("$err",qr/INVALID_TARGET/,'wrapper throws diagnostic execution object');

for my $limit (qw(ops mem new_obj depth)) {
   $exec=JGraft::Exec->new(jgraft=>COPY(1,'x'),limits=>{$limit=>0});
   @result=$exec->apply({});
   is($exec->error,'RESOURCE_LIMIT',"$limit enforced");
   is(\@result,[],"$limit failure has no return value");
}
$exec=JGraft::Exec->new(jgraft=>JGRAFT({expr=>['loop',EXPR('loop')]},COPY(EXPR('loop'),NODE())),limits=>{depth=>40});
$exec->apply(1);
is($exec->error,'RESOURCE_LIMIT','recursive macro expansion bounded');
$exec=JGraft::Exec->new(jgraft=>COPY(NODE('x'),NODE()));
$exec->apply({});
@result=$exec->apply({x=>0});
is(\@result,[0],'executor reusable after failure');
is($exec->error,undef,'reapplication clears diagnostic');

for my $value (1,'1',undef,JSON::PP::false) {
   my $before=$json->encode($value);
   type_mask($value); is_finite($value); is_integer($value);
   is($json->encode($value),$before,'type predicates preserve scalar flags');
}
is([TYPE_NONE,TYPE_NULL,TYPE_BOOLEAN,TYPE_NUMBER,TYPE_STRING,TYPE_ARRAY,TYPE_OBJECT,TYPE_DATE,TYPE_ANY],
   [0,1,2,4,8,16,32,64,127],'exported type constants retain their bit assignments');
is(TYPE_NULL | TYPE_BOOLEAN | TYPE_NUMBER | TYPE_STRING | TYPE_ARRAY | TYPE_OBJECT | TYPE_DATE,
   TYPE_ANY,'TYPE_ANY includes all type bits');
is(type_mask(1),TYPE_NUMBER,'number type');
is(type_mask('1'),TYPE_STRING,'string type');
ok(!is_finite('1'),'numeric string is not numeric data');

$exec=JGraft::Exec->new(jgraft=>'["JGRAFT",{},["COPY",2,"x"]]');
is([$exec->apply({})],[{x=>2}],'JSON text graft accepted');
$exec=JGraft::Exec->new(jgraft=>['JGRAFT',{},['COPY',2,'x']]);
is([$exec->apply({})],[{x=>2}],'JSON-data graft accepted');
$exec=JGraft::Exec->new(jgraft=>JGRAFT());
my $cycle=[];push @$cycle,$cycle;
$exec->apply($cycle);
is($exec->error,'INVALID_TARGET','cyclic input rejected');
$exec->apply(NODE());
is($exec->error,'UNSUPPORTED_GRAFT','expression objects are not input data');
$exec->apply(BOOL());
is($exec->error,'UNSUPPORTED_GRAFT','boolean expressions are not boolean data');
done_testing;
