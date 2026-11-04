use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;

my %supported=map {$_=>1} qw(JGRAFT AT ATSPLIT SPLIT JOIN MATCH IF COPY MOVE EXPR NODE TEMP STASH CONST CAP
   HAS IS NONE ANY ALL EXISTS ARRAY STR NUM BOOL WITH CAPTURE CURPROP DATE CASTDATE LESS LESSEQ CHARS SEQ SEQMIN SEQMAX REP START END
   FAIL LENGTH SLICE LOCAL AND OR NOT CASTBOOL CASTNUM CASTSTR ADD MUL SUB DIV MOD);
for my $file (qw(11-seq-any 12-seq-all 13-seq-none 14-rep 17-array 23-with 35-start-end 36-capture)) {
   test_conformance("jgraft-spec/conformance/$file.json",supported=>\%supported);
}
done_testing;
