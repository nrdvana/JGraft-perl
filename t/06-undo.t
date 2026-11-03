use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec jgparse);
use JGraft::Exec;
use JSON::PP ();
use Scalar::Util qw(refaddr weaken);
my $json=JSON::PP->new->canonical->allow_nonref;

sub round_trip {
   my ($name,$input,$graft,%options)=@_;
   my $before=$json->encode($input);
   my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1,%options);
   $exec->apply($input);
   my $error=$exec->error;
   my $output=$json->encode($exec->output);
   my $undo=$exec->undo;
   my $data=$undo->to_json_data;
   my $encoded=$json->encode($data);
   my $restored=JGraft::Exec->new(jgraft=>jgparse($json->decode($encoded)));
   $restored->apply($exec->output);
   ok($restored->success,"$name: serialized undo executes") or diag "$restored",explain($data);
   is($json->encode($restored->output),$before,"$name: restores original");
   is($json->encode($exec->output),$output,"$name: undo preserves output");
   is($json->encode($input),$before,"$name: input preserved");
   is($exec->error,$error,"$name: diagnostics preserved");
   is(refaddr($exec->undo),refaddr($undo),"$name: undo cached");
   return ($exec,$data,$encoded);
}

my $big={payload=>('KEEP_THIS_SUBTREE_' x 10000),nested=>[1,2,3]};
my ($exec,$data,$encoded)=round_trip('one leaf',{a=>{x=>1},big=>$big},COPY(2,NODE('a','x')));
is($data,['JGRAFT',{v=>1},['AT',['NODE','a'],['COPY',1,['NODE','x']]]],'leaf edit uses a relative AT scope');
($exec,$data,$encoded)=round_trip('repeated writes',{x=>1,big=>$big},JGRAFT(COPY(2,'x'),COPY(3,'x'),COPY(4,'x')));
is($data,['JGRAFT',{v=>1},['COPY',1,['NODE','x']]],'repeated writes collapse');
($exec,$data)=round_trip('net no change',{x=>1},JGRAFT(COPY(2,'x'),COPY(1,'x')));
is($data,['JGRAFT',{v=>1}],'cancelled edits produce no actions');
($exec,$data)=round_trip('autovivify',{},COPY(1,NODE('new','array',0,'value')));
is($data,['JGRAFT',{v=>1},['MOVE',['NODE','new'],undef]],'undo removes first added ancestor');

($exec,$data,$encoded)=round_trip('relocate large subtree',{a=>$big},MOVE('a','b'));
ok(length($encoded)<1000,'relocation undo does not embed moved subtree');
unlike($encoded,qr/KEEP_THIS_SUBTREE_/,'relocation uses output reference');
($exec,$data,$encoded)=round_trip('relocate and edit',{a=>$big},JGRAFT(MOVE('a','b'),COPY(9,NODE('b','nested',1))));
ok(length($encoded)<2000,'modified relocated subtree is restored with small edits');
($exec,$data,$encoded)=round_trip('relocate and edit with clone',{a=>$big},JGRAFT(MOVE('a','b'),COPY(9,NODE('b','nested',1))),clone=>1);
ok(length($encoded)<2000,'clone output also reuses relocated subtrees');
($exec,$data,$encoded)=round_trip('delete subtree',{a=>$big,untouched=>{marker=>'UNCHANGED'}},MOVE('a',undef));
like($encoded,qr/KEEP_THIS_SUBTREE_/,'deleted subtree retained');
unlike($encoded,qr/UNCHANGED/,'unrelated subtree omitted');
round_trip('overwrite subtree',{a=>{old=>[1,2]},big=>$big},COPY({new=>3},'a'));
round_trip('temporary round trip',{a=>$big},MOVE('a',TEMP(0),TEMP(0),'b'));
round_trip('scoped and dynamic paths',{list=>[{x=>1}],dest=>'x'},AT(NODE('list',0),COPY(7,NODE('x'))));
round_trip('namespace edits only',{x=>1},JGRAFT(COPY(1,STASH('a')),COPY(STASH('a'),TEMP(0))));
round_trip('arbitrary keys',{'__proto__'=>1,''=>2,'1'=>3},COPY(4,'__proto__',5,'',6,'1'));
round_trip('numeric string distinction',{n=>1,s=>'1',f=>JSON::PP::false},COPY('1','n',1,'s',JSON::PP::true,'f'));

for my $case (
   ['array deletion',[0,1,2,3],MOVE(1,undef)],
   ['array append',[0,1],COPY([2,3],NODE(JSON::PP::false))],
   ['array half insertions',[0,1,2],MOVE(2,-.5,undef,.5,undef,.5)],
   ['array duplicate matches',[1,2,1,2,1],MOVE(0,3.5,2,undef)],
   ['array pending metadata moved',{a=>[1,2,3]},MOVE(NODE('a',0),NODE('a',1.5),'a','b')],
   ['array delete and restore',[1,2,3],MOVE(0,TEMP(0),TEMP(0),0)],
   ['array current root deleted',[1,2],MOVE(NODE(),undef)],
   ['root replacement',{a=>[1,2]},COPY(undef,NODE())],
   ['failed after deletion',[1,2,3],MOVE(0,undef,0,undef)],
   ['failed after overwrite',{a=>1},COPY(2,'a',NODE('absent'),'b')],
   ['failed after autovivify',{},COPY(1,NODE('a',0,'x'),NODE('absent'),'b')],
   ['empty input array',[],MOVE(undef,-.5)],
) { round_trip(@$case) }

my @objects=map {{value=>$_,big=>$big}} 0..99;
($exec,$data,$encoded)=round_trip('long array rotation',\@objects,MOVE(99,-.5));
ok(length($encoded)<2000,'array rotation undo size follows edits, not array length or payload size');

# Borrowed original is needed until the lazy calculation; the resulting graft
# must release unrelated original ancestors once calculation finishes.
my $original={a=>1,big=>$big};
my $weak=$original;weaken($weak);
$exec=JGraft::Exec->new(jgraft=>COPY(2,'a'),undo=>1);
$exec->apply($original);
undef $original;
ok(defined $weak,'original retained before lazy calculation');
my $counters=$exec->counters;
my $undo=$exec->undo;
ok($exec->success,'undo calculation preserves execution success');
is($exec->error,undef,'undo calculation preserves execution diagnostic');
is($weak,undef,'calculated undo releases original root');
is($exec->counters,$counters,'lazy calculation does not change execution counters');
my $limited=JGraft::Exec->new(jgraft=>$undo,limits=>{ops=>0});
$limited->apply($exec->output);
is($limited->error,'RESOURCE_LIMIT','applying undo enforces its own limits');
is(jgexec($undo,$exec->output),{a=>1,big=>$big},'fresh default limits apply undo successfully');

sub longest_path {
   my $value=shift;
   my $max=0;
   if (ref($value) eq 'ARRAY') {
      my $token=$value->[0];
      $max=@$value-1 if defined($token) && !ref($token) && $token eq 'NODE';
      for (@$value) { my $n=longest_path($_); $max=$n if $n>$max }
   }
   elsif (ref($value) eq 'HASH') {
      for (values %$value) { my $n=longest_path($_); $max=$n if $n>$max }
   }
   return $max;
}
my @sizes;
for my $depth (12,24) {
   my $input={};
   my $node=$input;
   my (@path,@actions);
   for (1..$depth) {
      $node->{value}=1;
      push @actions,COPY(2,NODE(@path,'value'));
      $node=$node->{child}={} if $_<$depth;
      push @path,'child';
   }
   ($exec,$data,$encoded)=round_trip("nested edits depth $depth",$input,JGRAFT(@actions));
   is(longest_path($data),1,'nested reverse edits only use single-selector paths');
   push @sizes,length($encoded);
}
ok($sizes[1]<2.2*$sizes[0],'nested undo size grows linearly with nesting depth');
($exec,$data)=round_trip('nested relocation captures',{a=>{x=>1},b=>{y=>2}},
   MOVE('a',NODE('new','c','d','a'),'b',NODE('new','c','d','b')));
is(longest_path($data),1,'relocation captures also use relative AT scopes');

# Generation has no implicit depth limit, even when deeper than the default
# execution limit. Applying that undo remains an independently limited operation.
my $deep={};
my $node=$deep;
my @path;
for (1..300) { $node=$node->{child}={}; push @path,'child' }
$node->{value}=1;
$exec=JGraft::Exec->new(jgraft=>COPY(2,NODE(@path,'value')),undo=>1,limits=>{depth=>2000});
$exec->apply($deep);
ok($exec->success,'deep forward edit allowed by explicit execution limits');
$undo=$exec->undo;
my $action=$undo->actions->[0];
my $scopes=0;
while ($action->isa('JGraft::Action::AT')) { ++$scopes; $action=$action->actions->[0] }
is($scopes,300,'undo generation traverses beyond the default depth limit');
$limited=JGraft::Exec->new(jgraft=>$undo,limits=>{depth=>40});
$limited->apply($exec->output);
is($limited->error,'RESOURCE_LIMIT','applying deep undo enforces a fresh depth limit');
my $restore=JGraft::Exec->new(jgraft=>$undo,limits=>{depth=>2000});
$restore->apply($exec->output);
ok($restore->success,'deep undo succeeds with suitable fresh limits');
$node=$restore->output;
$node=$node->{child} for 1..300;
is($node->{value},1,'deep undo restores the leaf');

# Fail while creating a long path, to exercise partially-created ancestors.
for my $limit (qw(mem new_obj ops)) {
   my $graft=COPY(1,NODE('a',0,'b',0,'c',0,'d'));
   my $baseline=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $baseline->apply({});
   my $max=int($baseline->counters->{$limit});
   for my $fraction (.4,.6,.8) {
      round_trip("$limit partial budget $fraction",{},$graft,limits=>{$limit=>int($max*$fraction)});
   }
}
round_trip('zero execution budget',{},COPY(1,'x'),limits=>{mem=>0});
$exec=JGraft::Exec->new(jgraft=>COPY(2,'a'),undo=>1);
$exec->apply({a=>1});
my $first=$exec->undo;
$exec->apply({a=>3});
is(jgexec($exec->undo,$exec->output),{a=>3},'reuse replaces lazy undo state');
is(jgexec($first,{a=>2}),{a=>1},'previous undo remains usable');
$exec=JGraft::Exec->new(jgraft=>JGRAFT());
$exec->apply({});
is($exec->undo,undef,'undo remains opt in');
done_testing;
