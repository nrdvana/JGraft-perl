use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JGraft::Util qw(:types type_mask is_finite is_integer);
use Scalar::Util qw(refaddr blessed weaken);
use JSON::PP ();
my $json=JSON::PP->new->canonical->allow_nonref;
{
   package Test::DispatchLength;
   our @ISA=('JGraft::Expr::LENGTH');
   sub _execute { 42 }
}
{
   my $expr=bless {%{LENGTH('abc')}},'Test::DispatchLength';
   is($expr->name,'LENGTH','subclasses inherit the declared directive name');
   is(Test::DispatchLength->name,'LENGTH','subclass class calls inherit the declared directive name');
   is(jgexec(COPY($expr,NODE()),undef),42,'execution still dispatches overridden node methods');
}

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
{
   package Local::ScratchExec;
   our @ISA=('JGraft::Exec');
   sub _scratch_set {
      my ($self,$base,$bytes)=@_;
      push @{$self->{workspaces}},[$bytes,$self->{count}{mem}+$base+$bytes]
         if $self->{moving};
      return $self->SUPER::_scratch_set($base,$bytes);
   }
}
{
   my $graft=MOVE(NODE('a',0),undef,NODE('b',0),undef);
   my $input={a=>[1..100],b=>[1..200]};
   my $baseline=Local::ScratchExec->new(jgraft=>$graft,undo=>1);
   $baseline->apply($input);
   ok($baseline->success,'large deferred MOVE baseline succeeds');
   my ($second)=grep $_->[0]>5000,@{$baseline->{workspaces}};
   ok($second,'second array extends the shared MOVE workspace');
   my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>{mem=>$second->[1]-1});
   $limited->apply($input);
   is($limited->error,'RESOURCE_LIMIT','MOVE workspace growth can fail after earlier deletion');
   like($limited->message,qr/scratch/,'MOVE reports scratch exhaustion');
   is($limited->output,{a=>[2..100],b=>[1..200]},'earlier deletion finalized despite failed workspace growth');
   is($input,{a=>[1..100],b=>[1..200]},'scratch failure preserves MOVE input');
   is(jgexec($limited->undo,$limited->output),$input,'undo restores MOVE after scratch exhaustion');
   is($limited->{scratch_mem},0,'MOVE failure releases all batch workspace');
   $limited->apply({a=>[1,2],b=>[3,4]});
   ok($limited->success,'MOVE context reusable after scratch exhaustion');
}

{
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
   $exec->apply(undef);
   my $owned=$exec->_alloc_array(3);
   my $id=refaddr($owned);
   my $weak=$owned;
   weaken($weak);
   undef $owned;
   is($weak,undef,'ownership capacity records do not retain discarded containers');
   is($exec->{containers}{$id}{ref},undef,'expired ownership identity is detectable');
   # Simulate an allocator reusing the expired address without depending on
   # interpreter-specific allocation order.
   my $borrowed=[1];
   $exec->{containers}{refaddr($borrowed)}=$exec->{containers}{$id};
   my $copy=$exec->_cow($borrowed);
   isnt(refaddr($copy),refaddr($borrowed),'expired record cannot confer writable ownership');
   is($copy,[1],'guarded cloning preserves the borrowed value');
}
{
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
   $exec->apply(undef);
   my $borrowed=[1];
   my $count=$exec->counters;
   is($exec->_container($borrowed),undef,'unannotated reads need no container record');
   is($exec->counters,$count,'record lookup allocates no retained metadata');
   my $array=$exec->_alloc_array(3);
   my $record=$exec->_container($array);
   my $serial=$record->{id};
   is($record->{kind},'ARRAY','record retains the container kind');
   $exec->_mark_date_container($array);
   $exec->_split_meta($array,{origin=>1,rows=>[[':', '', '']],separators=>1});
   $record->{pending}={deleted=>{0=>1}}; # Stale fields must all fail the same guard.
   my $weak=$array;
   weaken($weak);
   undef $array;
   is($weak,undef,'split and date metadata do not retain a discarded owner');
   $exec->{containers}{refaddr($borrowed)}=$record;
   is($exec->_split_meta($borrowed),undef,'expired split metadata cannot attach to a reused address');
   ok(!$exec->_contains_date($borrowed),'expired date summary cannot attach to a reused address');
   {
      local $exec->{moving}=1;
      ok($exec->_present($borrowed,0),'expired pending metadata cannot hide a new array element');
   }
   my $fresh=$exec->_container($borrowed,1);
   cmp_ok($fresh->{id},'>',$serial,'replaced identities receive increasing serial IDs');
   is($fresh->{owner_epoch},0,'borrowed metadata does not confer writable ownership');
   my $other=[2];
   $exec->{containers}{refaddr($other)}=$fresh;
   is($exec->_container($other),undef,'a live record under the wrong address is also rejected');
   isnt(refaddr($exec->_cow($other)),refaddr($other),'mismatched live identity cannot confer ownership');
   is($other,[2],'identity checks preserve caller data');
}

{
   my $pending=JGraft::Exec->can('_pending');
   my (@records,@arrays);
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT(MOVE(0,undef),COPY('done',NODE())));
   {
      no warnings 'redefine';
      local *JGraft::Exec::_pending=sub {
         my $state=$pending->(@_);
         push @records,$state->{record};
         push @arrays,$state->{array};
         weaken($arrays[-1]);
         return $state;
      };
      $exec->apply([1,2,3]);
   }
   ok($exec->success,'deferred array can be discarded after MOVE finalization');
   is($exec->output,'done','later root replacement succeeds after finalization');
   ok(@records && !grep(exists($_->{pending}),@records),'finalization clears pending links on retained records');
   ok(!grep(defined($_),@arrays),'batch and records release discarded MOVE arrays');
}

# Exercise the private budget boundary: public mem alone cannot describe live
{
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT(),undo=>1);
   my $input={a=>{x=>1},keep=>[2]};
   $exec->_init_application($input);
   require JGraft::_Undo;
   $exec->{undo_state}=JGraft::_Undo->_new($exec,$input);
   my $base=$exec->{scratch_mem};
   local $exec->{scratch_mem}=$base;
   local $exec->{path_workspace}=[$base,0];
   my $trace=$exec->_resolve([$exec->{root},['a','x'],'node'],'write');
   $exec->_assign([$exec->{root},['a'],'node'],{x=>7});
   $exec->_assign($trace,9);
   is($exec->{root}[0],{a=>{x=>9},keep=>[2]},'stale traces rebind canonical keys after ancestor replacement');
   is($input,{a=>{x=>1},keep=>[2]},'trace rebinding preserves borrowed input');
   $exec->{undo_state}{output}=$exec->{root}[0];
   is(jgexec($exec->undo->to_json_data,$exec->{root}[0]),$input,'stale-trace edits retain valid serialized undo');
}
{
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
   $exec->apply(undef);
   my $array=[1,2];
   my @raw;
   local $exec->{path_remap}=sub {
      my ($self,$record,$key,$mode)=@_;
      push @raw,[$record->{id},$key,$mode];
      return 0;
   };
   is($exec->_selector(-1,$array,0),0,'optional internal remapping precedes negative-index aliases');
   is($raw[0][1],-1,'remapping receives the raw selector');
   is($array,[1,2],'the inactive-by-default extension does not require tied arrays');
}

# Exercise the private budget boundary: public mem alone cannot describe live
# workspace, and a failed reservation must retain consumed public counters.
{
   my $budget=JGraft::Exec->new(jgraft=>JGRAFT());
   $budget->apply(undef);
   $budget->{count}{mem}=4096;
   $budget->{limits}{mem}=10240;
   {
      local $budget->{scratch_mem}=0;
      $budget->_scratch_set(0,5120);
      is($budget->counters->{mem},4096,'scratch does not accumulate in public mem');
      {
         my $base=$budget->{scratch_mem};
         local $budget->{scratch_mem}=$base;
         my $error=dies { $budget->_scratch_set($base,2048) };
         is(refaddr($error),refaddr($budget),'nested workspace enforces combined memory limit');
         like($budget->message,qr/scratch/,'scratch failure identifies workspace');
      }
      is($budget->{scratch_mem},5120,'nested failure restores outer reservation');
      my $error=dies { $budget->_reserve(0,2048,0) };
      is(refaddr($error),refaddr($budget),'retained allocation checks active scratch');
      is($budget->counters->{mem},6144,'failed retained charge remains consumed');
   }
   is($budget->{scratch_mem},0,'outer scratch reservation unwinds');
   $budget->{count}{mem}=4096;
   for (1..3) {
      local $budget->{scratch_mem}=0;
      $budget->_scratch_set(0,5120);
   }
   is($budget->counters->{mem},4096,'completed scratch reservations do not accumulate');
   $budget->{limits}{mem}=5120;
   {
      local $budget->{scratch_mem}=0;
      $budget->_scratch_set(0,1024);
      is($budget->{scratch_mem},1024,'small scratch remains fully reserved across tracked calls');
      my $retained=dies { $budget->_reserve(0,1,0) };
      is(refaddr($retained),refaddr($budget),'retained allocation cannot consume reserved small scratch');
      $budget->{count}{mem}=4096;
      my $error=dies { $budget->_scratch_set(0,1025) };
      is(refaddr($error),refaddr($budget),'1025 bytes checks the full workspace');
      is($budget->{scratch_mem},1025,'workspace estimate includes first 1024 bytes');
   }
   $budget->apply(undef);
   ok($budget->success,'context reuse clears scratch failure');
   is($budget->{scratch_mem},0,'reuse starts with zero scratch');
}
{
   no warnings 'utf8'; # Intentional noncharacter for the policy callback.
   my $plain=JGraft::Exec->new(jgraft=>JGRAFT());
   my $wide=JGraft::Exec->new(jgraft=>JGRAFT());
   $plain->apply('a' x 2000);
   $wide->apply("\x{100}" x 2000);
   is($wide->counters->{mem},$plain->counters->{mem},'Unicode validation scan is call-owned scratch');
   is($wide->{scratch_mem},0,'successful validation releases scratch');
   my $exception=bless {},'Local::PolicyException';
   my $throwing=JGraft::Exec->new(jgraft=>JGRAFT(),codepoint_policy=>sub { die $exception });
   my $error=dies { $throwing->apply("\x{FDD0}" x 2000) };
   is(refaddr($error),refaddr($exception),'callback exception propagates unchanged');
   is($throwing->{scratch_mem},0,'callback exception unwinds scratch');
   $throwing->apply('safe');
   ok($throwing->success,'context reused after callback exception');
}
{
   my @path=('branch')x40;
   my $input={leaf=>0};
   $input={branch=>$input} for @path;
   my @mem;
   for my $count (1,20) {
      my @assignments=map {($_,NODE(@path,'leaf'))} 1..$count;
      my $exec=JGraft::Exec->new(jgraft=>COPY(@assignments));
      $exec->apply($input);
      ok($exec->success,'long destination paths succeed');
      is($exec->{scratch_mem},0,'pair-owned path workspace unwinds');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'completed path expansions do not accumulate retained mem');
   my $graft=JGRAFT(COPY(7,'before'),COPY(1,NODE(@path,'leaf')));
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply($input);
   ok($baseline->success,'long path with undo baseline succeeds');
   my $limits={mem=>$baseline->counters->{mem}};
   my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>$limits);
   $limited->apply($input);
   is($limited->error,'RESOURCE_LIMIT','path workspace stays charged during ancestor preparation');
   like($limited->message,qr/scratch/,'path limit failure identifies active scratch');
   is($limited->output,{%$input,before=>7},'path preparation failure retains prior edit');
   is($limited->{scratch_mem},0,'path failure releases reservations');
   test_conformance({name=>'long path scratch failure',input=>$input,
      jgraft=>$graft->to_json_data,limits=>$limits,errors=>{RESOURCE_LIMIT=>1}});
   my $nested=JGRAFT(COPY(7,'before'),AT(NODE(@path),AT(NODE(),COPY(1,'leaf'))));
   my $nested_base=JGraft::Exec->new(jgraft=>$nested,undo=>1);
   $nested_base->apply($input);
   ok($nested_base->success,'nested AT keeps long canonical locations valid');
   my $nested_limited=JGraft::Exec->new(jgraft=>$nested,undo=>1,
      limits=>{mem=>$nested_base->counters->{mem}});
   $nested_limited->apply($input);
   is($nested_limited->error,'RESOURCE_LIMIT','nested AT reservations remain live during child mutation');
   like($nested_limited->message,qr/scratch/,'nested AT failure identifies live workspace');
   is($nested_limited->{scratch_mem},0,'nested AT failure restores outer scratch');
   test_conformance({name=>'nested AT scratch failure',input=>$input,
      jgraft=>$nested->to_json_data,limits=>{mem=>$nested_base->counters->{mem}},errors=>{RESOURCE_LIMIT=>1}});
}
{
   no warnings 'utf8';
   my @path=('branch')x40;
   my $key='leaf'.chr(0xfdd0);
   my $input={$key=>0};
   $input={branch=>$input} for @path;
   my ($weak,$active);
   my $throw=1;
   my $sentinel="path callback exception\n";
   my $exec=JGraft::Exec->new(jgraft=>COPY(1,NODE(@path,$key)),codepoint_policy=>sub {
      if ($throw && $_[1]{kind} eq 'literal') {
         $active=$weak->{scratch_mem};
         $throw=0;
         die $sentinel;
      }
      return 'preserve';
   });
   $weak=$exec;
   weaken($weak);
   is(dies {$exec->apply($input)},$sentinel,'selector callback exception propagates');
   ok($active>1024,'selector callback runs while path expansion remains reserved');
   is($exec->{scratch_mem},0,'selector callback exception unwinds path reservation');
   $exec->apply($input);
   ok($exec->success,'context reusable after selector callback exception');
}
{
   my @mem;
   my $input;
   for my $size (16,512) {
      $input={map {('k'.$_=>$_)} 1..$size};
      my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
      $exec->apply($input);
      ok($exec->success,'inspection of borrowed wide object succeeds');
      is($exec->{scratch_mem},0,'inspection key and ancestor worksets unwind');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'inspection worksets are excluded from retained mem');
   my $limited=JGraft::Exec->new(jgraft=>JGRAFT(),undo=>1,limits=>{mem=>$mem[1]});
   $limited->apply($input);
   is($limited->error,'RESOURCE_LIMIT','inspection key vector must fit while live');
   like($limited->message,qr/scratch/,'inspection reports scratch exhaustion');
   is($limited->output,$input,'inspection failure preserves unedited output');
   is($limited->{scratch_mem},0,'inspection failure unwinds ancestor and key reservations');
   test_conformance({name=>'inspection workspace failure',input=>$input,
      jgraft=>JGRAFT()->to_json_data,limits=>{mem=>$mem[1]},errors=>{RESOURCE_LIMIT=>1}});
}
{
   no warnings 'utf8';
   my $input={map {('k'.$_=>$_)} 1..200};
   $input->{chr(0xfdd0)}=1;
   my ($weak,$active);
   my $throw=1;
   my $sentinel="inspection callback exception\n";
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT(),codepoint_policy=>sub {
      if ($throw && $_[1]{kind} eq 'input key') {
         $active=$weak->{scratch_mem};
         $throw=0;
         die $sentinel;
      }
      return 'preserve';
   });
   $weak=$exec;
   weaken($weak);
   is(dies {$exec->apply($input)},$sentinel,'inspection callback exception propagates');
   ok($active>1024,'inspection key vector remains covered during callback');
   is($exec->{scratch_mem},0,'inspection callback unwinds its worksets');
   $exec->apply($input);
   ok($exec->success,'inspection context reusable after callback exception');
}
{
   my $input={map {('key'.$_=>$_)} 1..300};
   for my $method (qw(_cow _clone_tree _eval)) {
      my $exec=JGraft::Exec->new(jgraft=>JGRAFT());
      $exec->apply(undef);
      my $objects=$exec->counters->{new_obj};
      my $bytes=80+($method eq '_cow'?32:16)*keys %$input;
      $exec->{limits}{mem}=$exec->counters->{mem}+$bytes-1;
      is(refaddr(dies {$exec->$method($input,1)}),refaddr($exec),
         'object transformation reserves its key vector before allocation');
      is($exec->error,'RESOURCE_LIMIT','key vector exhaustion reports the resource error');
      is($exec->counters->{new_obj},$objects,'key vector preflight fails before constructing the output container');
      is($exec->{scratch_mem},0,'object key workspace unwinds on failure');
      is($input,{map {('key'.$_=>$_)} 1..300},'object key-vector failure preserves input');
   }
}
done_testing;
