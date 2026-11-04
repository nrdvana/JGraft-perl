use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft;
use Storable qw(nfreeze thaw nstore);
use File::Temp 'tempdir';
use JSON::PP ();

my @classes;
for my $registry ('JGraft::Action', 'JGraft::Expr') {
   no strict 'refs';
   for my $name (sort keys %{$registry.'::by_name'}) {
      my $class= $registry->get_class($name);
      (my $file= "$class.pm") =~ s{::}{/}g;
      if ($class eq 'JGraft::Expr::CHARS') { ok(exists $INC{$file}, 'CHARS loads its implementation module') }
      else { ok(!exists $INC{$file}, "$class defined without opening its shim") }
      my $id= $class->id;
      my $base= $registry;
      if ($registry eq 'JGraft::Expr') {
         # Protocol IDs distinguish references, matches, and functions.
         $base .= '::'.($id <= 0? 'Ref' : $id < 50? 'Match' : 'Fn');
      }
      push @classes, [$class, $base, $id];
   }
}
for my $category ('Ref', 'Match', 'Fn') {
   my $class= "JGraft::Expr::$category";
   ok(!exists $INC{"JGraft/Expr/$category.pm"}, "$class defined without opening its shim");
   push @classes, [$class, 'JGraft::Expr'];
}

my $load= <<'PERL';
my ($class, $base, $id)= @ARGV;
$class->isa($base) or die "Incorrect inheritance for $class\n";
if (defined $id) {
   $class->id == $id or die "Incorrect ID for $class\n";
   ref($class->forms) eq 'ARRAY' or die "Missing forms for $class\n";
}
(my $file= "$class.pm") =~ s{::}{/}g;
my @shims= grep m{\AJGraft/(?:Action|Expr)/[^/]+\.pm\z}, keys %INC;
my @unexpected=grep $_ ne $file && $_ ne 'JGraft/Expr/CHARS.pm',@shims;
!@unexpected && exists $INC{$file} or die "Loaded extra shims: @shims\n";
PERL
for my $entry (@classes) {
   my ($status, $output)= run_perl('-M'.$entry->[0], '-e', $load, @$entry);
   is($status, 0, "$entry->[0] loads independently through its shim");
}

my $graft= JGraft::JGRAFT(JGraft::COPY(JGraft::ADD(1,JGraft::NODE('x')),'y'));
is(thaw(nfreeze($graft))->to_json_data, $graft->to_json_data, 'Storable round trip retains node behavior');
my $dir= tempdir(CLEANUP=>1);
my $file= "$dir/graft.storable";
nstore($graft, $file);
my $restore= <<'PERL';
use Storable 'retrieve';
use JSON::PP ();
my $graft= retrieve(shift @ARGV);
(my $module= ref($graft).'.pm') =~ s{::}{/}g;
require $module;
print JSON::PP->new->canonical->encode($graft->to_json_data);
PERL
my ($status, $output)= run_perl('-e', $restore, $file);
is($status, 0, 'cold process can load a restored object through its class shim');
is($output, JSON::PP->new->canonical->encode($graft->to_json_data), 'restored nested nodes retain accessors and serialization');
done_testing;
