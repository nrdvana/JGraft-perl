# Run with the selected generated library, for example:
# perl -Iblib/lib maint/bench-exec.pl 100
# Each time is one batch; graft construction and transport conversion are untimed.
use strict;
use warnings;
use JGraft qw(:constructors);
use JGraft::Exec;
use JGraft::JSON;
use Math::BigInt;
use Time::HiRes 'time';
my @writes=map {( $_, NODE('a','b','k'.$_))} 1..40;
my @long_path=('branch')x24;
my $long_input={map {('k'.$_=>0)} 1..8};
$long_input={branch=>$long_input} for @long_path;
my $big_a=Math::BigInt->new('1'x1000);
my $big_b=$big_a->copy->binc;
my @bindings=map {('k'.$_=>$_)} 1..300;
my $product_input={values=>[map {Math::BigInt->new(('1'x200).$_)} 1..3]};
my $split_spec={sep=>ANY(':','|'),default=>'/',trim=>REP(0,-1,CHARS(' '))};
my @work=(
 ['noop',JGRAFT(),{},{}],
 ['noop_undo',JGRAFT(),{a=>[1..100]},{undo=>1}],
 ['deep_writes',COPY(@writes),{a=>{b=>{}}},{}],
 ['long_paths',COPY(map {($_,NODE(@long_path,'k'.$_))} 1..8),$long_input,{}],
 ['snapshots',JGRAFT(COPY({nested=>{x=>1}},'a'),COPY(NODE('a'),'b'),COPY(2,NODE('a','nested','x'),3,NODE('b','nested','y'))),{},{}],
 ['move_failure',MOVE(0,undef,1,undef,0,undef),[1..100],{undo=>1}],
 ['literal',COPY([1..300],NODE()),{},{}],
 ['concat',COPY(CONCAT(NODE('a'),NODE('a')),NODE()),{a=>[1..300]},{}],
 ['slice_copy',COPY(SLICE(NODE('a'),10,200),NODE()),{a=>[1..300]},{}],
 ['map_identity',COPY(MAP(NODE(),NODE('a')),NODE()),{a=>[1..100]},{}],
 ['filter_defined',COPY(FILTER(EXISTS(),NODE('a')),NODE()),{a=>[1..100]},{}],
 ['splice',SPLICE(NODE('a',50),10,1,2,3),{a=>[1..100]},{}],
 ['match',MATCH({a=>NUM(),b=>[1,2,3]}),{a=>2,b=>[1,2,3]},{}],
 ['sequence_preparation',MATCH([SEQMAX('g'x300,REP())]),[1..16],{}],
 ['boolean_frontier',COPY(IS([SEQ(REP())]),NODE()),[1..40],{}],
 ['regex_retry',COPY(STR('z'),NODE()),'a'x200,{}],
 ['chars_compile',COPY(CHARS('abc'x50),NODE()),'b',{}],
 ['numeric_compare',COPY(LESS(NODE('a'),NODE('b')),'result'),{a=>$big_a,b=>$big_b},{}],
 ['numeric_arithmetic',COPY(ADD(NODE('a'),NODE('b')),'result'),{a=>$big_a,b=>$big_a->copy->bneg},{}],
 ['numeric_growth',COPY(MUL(NODE('values')),'result'),$product_input,{}],
 ['native_arithmetic',COPY(ADD(NODE('values')),'result'),{values=>[1..100]},{}],
 ['numeric_format',COPY(CASTSTR(NODE('a')),'result'),{a=>$big_a},{}],
 ['numeric_clone',JGRAFT(),{a=>$big_a,b=>$big_b},{clone=>1}],
 ['local_copy',COPY(LOCAL(@bindings,LOCAL('k1',1,TEMP('k1'))),'result'),{},{}],
 ['namespace_inherit',JGRAFT({const=>[ @bindings ]},
    JGRAFT({const=>['extra',7]},COPY(CONST('k300'),'result'))),{},{}],
 ['wide_clone',JGRAFT(),{map {('k'.$_=>$_)} 1..300},{clone=>1}],
 ['date_export',JGRAFT(COPY(NODE(),STASH('object')),
    COPY(CASTDATE('2024-01-02'),STASH('object','date')),COPY(STASH('object'),NODE())),
    {a=>{keep=>1},b=>2},{}],
 ['join_config',COPY(JOIN(',',NODE('parts')),'result'),{parts=>[('x')x100]},{}],
 ['split_provenance',ATSPLIT(NODE(),$split_spec,
    COPY(map {(NODE(0),STASH('sink'))} 1..100)),' a :  b |   c ',{}],
 ['split_concat',JGRAFT(COPY(SPLIT($split_spec),STASH('parts')),
    COPY(JOIN($split_spec,CONCAT(STASH('parts'),STASH('parts'))),NODE())),
    join(': ',(' a ')x100),{}],
 ['unicode',COPY(LENGTH(NODE()),NODE()),"\x{100}" x 2000,{}],
 ['exact',COPY(2,NODE('a','x')),JGraft::JSON->new->decode('{"a":{"x":1,"x":3},"n":12345678901234567890}'),{}],
);
my $iterations=@ARGV? shift @ARGV : 100;
$iterations =~ /\A[1-9][0-9]*\z/ && !@ARGV or die "usage: $0 [iterations]\n";
my $codec=JGraft::JSON->new;
for my $w (@work) {
   my ($name,$graft,$original,$opt)=@$w;
   for my $transport (qw(native exact)) {
      my $input=$transport eq 'exact'? $codec->decode($codec->encode($original)) : $original;
      for my $mode (qw(reused fresh notation notation_fresh)) {
         my $syntax=$mode =~ /notation/? $graft->to_json_data : $graft;
         my $exec=JGraft::Exec->new(jgraft=>$syntax,%$opt);
         my @times;
         for (1..3) {
            my $start=time;
            for (1..$iterations) {
               $exec=JGraft::Exec->new(jgraft=>$syntax,%$opt) if $mode =~ /fresh/;
               $exec->apply($input);
               die $exec unless $exec->success || ($exec->error || '') eq 'INVALID_TARGET' && $name eq 'move_failure';
            }
            push @times,sprintf('%.6f',time-$start);
         }
         print "$name/$transport/$mode @times counters ",
            join(' ',map {$_.'='.$exec->counters->{$_}} qw(ops mem new_obj depth)),"\n";
      }
   }
}
