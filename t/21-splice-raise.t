use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JSON::PP ();
use Scalar::Util 'refaddr';

my $input={items=>[{x=>1},{x=>2}],untouched=>['keep']};
my $exec=JGraft::Exec->new(jgraft=>JGRAFT(
   COPY(NODE('items'),STASH('saved')),
   RAISE('info','before',NODE('items')),
   SPLICE(NODE('items',0),1,NODE('items',1)),
   COPY(9,NODE('items',0,'x')),
   RAISE('warn','after',NODE('items')),
   COPY(STASH('saved'),'saved')),undo=>1);
$exec->apply($input);
ok($exec->success,'splice and diagnostics coexist with logical copies');
is($exec->output,{items=>[{x=>9},{x=>2}],saved=>[{x=>1},{x=>2}],untouched=>['keep']},
   'SPLICE freezes replacement aliases and preserves stash snapshots');
is($exec->logs,[{level=>0,message=>'before',data=>[{x=>1},{x=>2}]},
   {level=>1,message=>'after',data=>[{x=>9},{x=>2}]}],'logged data retains its original snapshot');
is(refaddr($exec->output->{untouched}),refaddr($input->{untouched}),'unrelated branches remain shared');
is(jgexec($exec->undo,$exec->output),$input,'combined splice/log execution has a valid undo');
is($input->{items},[{x=>1},{x=>2}],'original input remains unchanged');

$exec=JGraft::Exec->new(jgraft=>JGRAFT(SPLICE(NODE('items',1),1,3),
   AT('items',RAISE('fail','stop',NODE())),COPY(1,'unreachable')),undo=>1);
$exec->apply($input);
is($exec->error,'NO_MATCH','fatal RAISE rejects the graft');
is($exec->message,'stop','fatal RAISE supplies the failure message');
is($exec->diagnostic->{path},['items'],'fatal RAISE retains the current scope');
isa_ok($exec->diagnostic->{action},['JGraft::Action::RAISE'],'fatal diagnostic identifies RAISE');
is($exec->output->{items},[{x=>1},3],'fatal RAISE retains preceding edits');
is($exec->logs,[{level=>2,message=>'stop',data=>[{x=>1},3]}],'fatal record is available after failure');
is(jgexec($exec->undo,$exec->output),$input,'undo restores the partial result after RAISE');

my $reuse=JGraft::Exec->new(jgraft=>RAISE('info',NODE('message'),NODE('data')));
is($reuse->logs,[],'logs are empty before the first application');
$reuse->apply({message=>'first',data=>[1]});
my $prior=$reuse->logs;
$reuse->apply({message=>'second',data=>[2]});
is($reuse->logs,[{level=>0,message=>'second',data=>[2]}],'new application starts a fresh log');
is($prior,[{level=>0,message=>'first',data=>[1]}],'previous application records remain stable');
$reuse->apply({message=>"bad\n",data=>[3]});
is($reuse->error,'INVALID_TARGET','invalid dynamic messages fail before recording');
is($reuse->logs,[],'failed application does not retain earlier records');

for my $cp (0,0x1f,0x7f,0x9f,0xd800,0xdfff,0xfdd0,0xfdef,map {($_<<16)+0xfffe,($_<<16)+0xffff} 0..16) {
   no warnings 'utf8';
   my $text='a'.chr($cp).'b';
   $exec=JGraft::Exec->new(jgraft=>RAISE('info',NODE()));
   $exec->apply($text);
   is($exec->error,'INVALID_TARGET',sprintf('dynamic message rejects U+%X on all interpreters',$cp));
   is($exec->logs,[],'invalid Unicode message emits no record');
}

my $dates=JGRAFT(COPY([],STASH('box','items')),
   SPLICE(STASH('box','items',0),0,CASTDATE('2024-02-29')),
   RAISE('info','date',STASH('box')),COPY(STASH('box'),NODE()));
my $formatted=0;
$exec=JGraft::Exec->new(jgraft=>$dates,date_format=>sub { ++$formatted; 'formatted' });
$exec->apply(undef);
ok($exec->success,'spliced dates can remain internal until exported');
is($exec->logs,[{level=>0,message=>'date',data=>{items=>['formatted']}}],'logs use the selected date formatter');
is($exec->output,{items=>['formatted']},'SPLICE propagates date tracking through namespace ancestors');
is($formatted,1,'log and output share the date export cache');

# Undo should describe the small edit, not embed the unchanged large payloads.
my $large=[map {{i=>$_,payload=>('UNCHANGED_PAYLOAD_'x100)}} 0..79];
$exec=JGraft::Exec->new(jgraft=>SPLICE(30,1,{i=>'new'}),undo=>1);
$exec->apply($large);
my $json=JSON::PP->new->canonical;
my $encoded=$json->encode($exec->undo->to_json_data);
ok(length($encoded)<2500,'SPLICE undo size follows the deleted subtree and edited span');
is(jgexec($exec->undo,$exec->output),$large,'small undo restores a large spliced array');

# Fail at different late execution points, including metadata preparation and
# after an earlier action changed the input. Each undo gets a fresh budget.
my $graft=JGRAFT(COPY(SPLIT({sep=>ANY(':','|'),trim=>' '},' a : b|c '),STASH('parts')),
   RAISE('info','snapshot',NODE()),SPLICE(NODE('items',1),1,STASH('parts',0),STASH('parts',1)),
   RAISE('warn','changed',NODE()),COPY(1,'finished'));
my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
$baseline->apply($input);
ok($baseline->success,'resource-test baseline succeeds');
for my $counter (qw(ops mem new_obj)) {
   my $max=int($baseline->counters->{$counter});
   for my $fraction (.5,.8,.95) {
      $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>{$counter=>int($max*$fraction)});
      $exec->apply($input);
      is($exec->error,'RESOURCE_LIMIT',"$counter resource failure is reported");
      is(jgexec($exec->undo,$exec->output),$input,"$counter failure has a valid undo");
      is($input->{items},[{x=>1},{x=>2}],"$counter failure preserves input");
      if (@{$exec->logs}) {
         is($exec->logs->[0]{data},$input,"$counter failure preserves recorded snapshots");
      }
   }
}
done_testing;
