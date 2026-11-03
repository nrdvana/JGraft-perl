use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;

my %supported=map {$_=>1} qw(JGRAFT AT MATCH IF COPY MOVE EXPR NODE TEMP STASH CONST CAP
   HAS IS NONE ANY ALL EXISTS ARRAY STR NUM BOOL WITH CAPTURE CURPROP CHARS SEQ SEQMIN SEQMAX REP START END
   FAIL LENGTH SLICE LOCAL AND OR NOT CASTBOOL CASTNUM CASTSTR ADD MUL SUB DIV MOD);
for my $file (qw(26-chars 29-curprop)) {
   test_conformance("jgraft-spec/conformance/$file.json",supported=>\%supported);
}
done_testing;
