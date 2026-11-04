use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;

my @files=sort glob 'jgraft-spec/conformance/*.json';
if (@files) {
   ok(@files>=37,'all standard conformance files are available');
   test_conformance($_) for @files;
}
else {
   SKIP: { skip 'jgraft-spec conformance fixtures are unavailable',1 }
}
done_testing;
