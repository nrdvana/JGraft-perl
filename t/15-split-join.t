use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;

my %supported=map {$_=>1} qw(JGRAFT AT ATSPLIT SPLIT JOIN MATCH IF COPY MOVE EXPR NODE TEMP STASH CONST CAP
   HAS IS NONE ANY ALL EXISTS ARRAY STR NUM BOOL WITH CAPTURE CURPROP DATE CASTDATE LESS LESSEQ CHARS SEQ SEQMIN SEQMAX REP START END
   FAIL LENGTH SLICE LOCAL AND OR NOT CASTBOOL CASTNUM CASTSTR ADD MUL SUB DIV MOD);
for my $file (qw(15-split-join)) {
   test_conformance("jgraft-spec/conformance/$file.json",supported=>\%supported);
}
done_testing;
