use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use File::Find ();

-d 'blib/lib' or bail_out('Build first: perl Makefile.PL && make; then prove -b');
my @modules;
File::Find::find({ no_chdir => 1, wanted => sub {
   push @modules, $File::Find::name if -f $_ && /\.pm\z/;
} }, 'blib/lib');
ok(scalar @modules, 'found built modules');
for my $file (sort @modules) {
   my $status= system($^X, '-Iblib/lib', '-Iblib/arch', '-c', $file);
   is($status, 0, "$file compiles");
}
done_testing;
