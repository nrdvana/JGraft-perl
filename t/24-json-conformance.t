use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft::JSON;

my @files=sort glob 'jgraft-spec/conformance/*.json';
if (@files) {
   ok(@files>=37,'all standard conformance files are available');
   my $json=JGraft::JSON->new(utf8=>1);
   test_conformance($_,json=>$json) for @files;
}
else {
   SKIP: { skip 'Specification conformance fixtures unavailable',1 }
}
done_testing;
