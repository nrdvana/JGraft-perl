use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors);
use JGraft::Exec;

my %supported=map {$_=>1} qw(JGRAFT AT ATSPLIT MATCH IF COPY MOVE EXPR NODE TEMP STASH CONST CAP
   HAS IS NONE ANY ALL EXISTS ARRAY STR NUM BOOL WITH CAPTURE CURPROP DATE CASTDATE LESS LESSEQ CHARS SEQ SEQMIN SEQMAX REP START END
   FAIL LENGTH SLICE LOCAL AND OR NOT CASTBOOL CASTNUM CASTSTR ADD MUL SUB DIV MOD SPLIT JOIN
   CONCAT REDUCE FILTER MAP PROPS MKOBJ CASE);
for my $file (qw(20-concat 21-mkobj 24-case 30-reduce 31-filter 32-map 34-props)) {
   test_conformance("jgraft-spec/conformance/$file.json",supported=>\%supported);
}

# All construction paths must propagate date-container tracking so the chosen
# formatter runs on export, including through pairs and parallel arrays.
my $date=CASTDATE('2024-02-29');
for my $case (
   ['CONCAT',CONCAT([$date]),['formatted']],
   ['REDUCE',REDUCE(NODE(),'acc',undef,[$date]),'formatted'],
   ['FILTER',FILTER(EXISTS(),[$date]),['formatted']],
   ['MAP',MAP(NODE(),[$date]),['formatted']],
   ['PROPS pairs',PROPS({date=>$date},1),[['date','formatted']]],
   ['PROPS parallel',PROPS({date=>$date},2),[['date'],['formatted']]],
   ['MKOBJ pairs',MKOBJ([['date',$date]]),{date=>'formatted'}],
   ['MKOBJ parallel',MKOBJ(['date'],[$date]),{date=>'formatted'}],
   ['MKOBJ arguments',MKOBJ('date',$date),{date=>'formatted'}],
   ['CASE',CASE(EXISTS(),$date),'formatted'],
) {
   my ($name,$expr,$expected)=@$case;
   my $calls=0;
   my $exec=JGraft::Exec->new(jgraft=>COPY($expr,NODE()),
      date_format=>sub { ++$calls; return 'formatted' });
   $exec->apply(undef);
   ok($exec->success,"$name date export succeeds") or diag "$exec";
   is($exec->output,$expected,"$name respects the date formatter");
   is($calls,1,"$name exports the date once");
}
done_testing;
