use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
require './maint/JGraftBuild.pm';

my $source= <<'PERL';
before
#__p5.28__
sub version { 'modern' }
#__p5.8__
#sub version { 'legacy' }
## A legacy comment

#__end__
after
PERL
my $legacy= <<'PERL';
before
#__p5.28__
#sub version { 'modern' }
#__p5.8__
sub version { 'legacy' }
# A legacy comment

#__end__
after
PERL
is(JGraftBuild::filter_source($source, 5.008009), $legacy, 'legacy branch selected');
is(JGraftBuild::filter_source($source, 5.027999), $legacy, 'workarounds apply below 5.28');
is(JGraftBuild::filter_source($source, 5.028), $source, 'modern branch starts at 5.28');
is(JGraftBuild::filter_source($source, 5.040001), $source, 'modern source unchanged');
is(JGraftBuild::filter_source('', 5.008009), '', 'empty source');
is(JGraftBuild::filter_source("plain\r\ntext", 5.008009), "plain\r\ntext", 'unmarked bytes preserved');
(my $crlf_source= $source) =~ s/\n/\r\n/g;
(my $crlf_legacy= $legacy) =~ s/\n/\r\n/g;
is(JGraftBuild::filter_source($crlf_source, 5.008009), $crlf_legacy, 'CRLF preserved');

for my $case (
   ['orphan legacy', "#__p5.8__\n", 'legacy branch must follow'],
   ['orphan end', "#__end__\n", 'end marker must follow'],
   ['nested block', "#__p5.28__\n#__p5.28__\n", 'nested modern branch'],
   ['missing legacy', "#__p5.28__\n#__end__\n", 'end marker must follow'],
   ['duplicate legacy', "#__p5.28__\n#__p5.8__\n#__p5.8__\n", 'legacy branch must follow'],
   ['missing end', "#__p5.28__\n#__p5.8__\n", 'unterminated version block'],
   ['active legacy code', "#__p5.28__\n#__p5.8__\ncode\n#__end__\n", 'legacy lines must start'],
   ['unknown version', "#__p5.16__\n", 'unknown or malformed'],
   ['malformed marker', "#__p5.28_\n", 'unknown or malformed'],
   ['indented marker', " #__p5.28__\n", 'unknown or malformed'],
) {
   for my $perl (5.008009, 5.028) {
      my $ok= eval { JGraftBuild::filter_source($case->[1], $perl, 'fixture.pm'); 1 };
      ok(!$ok, "$case->[0] rejected for $perl");
      like($@, qr/^fixture\.pm:\d+: \Q$case->[2]\E/, 'error identifies source and line');
   }
}
done_testing;
