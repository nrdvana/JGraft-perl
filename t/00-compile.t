use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use IPC::Open3;
use Symbol 'gensym';
use File::Find ();

-d 'blib/lib' or bail_out('Build first: perl Makefile.PL && make; then prove -b');
my @modules;
File::Find::find({ no_chdir => 1, wanted => sub {
   push @modules, $File::Find::name if -f $_ && /\.pm\z/;
} }, 'blib/lib');
ok(scalar @modules, 'found built modules');
for my $file (sort @modules) {
   my $err = gensym;
   my $pid = open3(undef, my $out, $err, $^X, '-Iblib/lib', '-Iblib/arch', '-c', $file);
   note do { local $/; <$err> };
   waitpid($pid, 0);
   is($?, 0, "$file compiles");
}
done_testing;
