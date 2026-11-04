use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;

my %supported=map {$_=>1} qw(JGRAFT AT ATSPLIT SPLIT JOIN COPY MOVE EXPR NODE TEMP STASH CONST CAP
   MATCH IF HAS IS NONE ANY ALL EXISTS ARRAY STR NUM BOOL WITH CAPTURE CURPROP DATE CASTDATE LESS LESSEQ
   CHARS SEQ SEQMIN SEQMAX REP START END
   FAIL LENGTH SLICE LOCAL AND OR NOT CASTBOOL CASTNUM CASTSTR ADD MUL SUB DIV MOD);
for my $file (qw(01-copy 02-move 16-jgraft-namespaces 25-fail 28-math 33-and-or-not)) {
   test_conformance("jgraft-spec/conformance/$file.json",supported=>\%supported);
}
done_testing;
