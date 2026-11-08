use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors);
use JGraft::Exec;

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
# Filling preallocated slots has the same retained growth through literal and
# collection builders. Compare slopes so fixed dispatch/namespace costs do not
# become part of the public contract.
{
   my %mem;
   for my $size (8,80) {
      my $input=[(0)x$size];
      my %object=map {sprintf('k%03d',$_)=>0} 1..$size;
      my @pairs=map {($_,0)} sort keys %object;
      for my $case (
         ['literal array',COPY([(0)x$size],NODE()),$input],
         ['SLICE',COPY(SLICE(NODE(),0,$size),NODE()),$input],
         ['MAP',COPY(MAP(0,NODE()),NODE()),$input],
         ['literal object',COPY(\%object,NODE()),\%object],
         ['MKOBJ',COPY(MKOBJ(@pairs),NODE()),\%object],
      ) {
         my ($name,$graft,$expected)=@$case;
         my $exec=JGraft::Exec->new(jgraft=>$graft);
         $exec->apply($input);
         ok($exec->success,"$name builds $size slots");
         is($exec->output,$expected,"$name preserves the constructed values");
         $mem{$name}{$size}=$exec->counters->{mem};
      }
   }
   my $array_growth=$mem{'literal array'}{80}-$mem{'literal array'}{8};
   is($array_growth,$mem{SLICE}{80}-$mem{SLICE}{8},'literal array does not buy reserved slots again');
   is($array_growth,$mem{MAP}{80}-$mem{MAP}{8},'MAP does not buy reserved slots again');
   is($mem{'literal object'}{80}-$mem{'literal object'}{8},$mem{MKOBJ}{80}-$mem{MKOBJ}{8},
      'object builders charge slots and key bytes consistently');
}
{
   my @mem;
   for my $index (0,JSON::PP::false) {
      my $exec=JGraft::Exec->new(jgraft=>JGRAFT(COPY([0..99],NODE()),
         SPLICE(NODE(1),99),COPY(7,NODE($index))));
      $exec->apply(undef);
      ok($exec->success,'edit after shrinking a constructed array succeeds');
      is($exec->output,ref($index)?[0,7]:[7],'append and overwrite retain their distinct results');
      push @mem,$exec->counters->{mem};
   }
   is($mem[1],$mem[0],'append after shrink uses already paid capacity');
}
done_testing;
