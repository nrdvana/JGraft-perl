use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft ();
use JGraft::Exec;
use JGraft::Util 'is_expr';
use Scalar::Util 'blessed';
use JSON::PP ();

plan skip_all => 'Conformance fixtures require the jgraft-spec checkout'
   unless -f 'jgraft-spec/conformance/01-copy.json';

my $json= JSON::PP->new->canonical->allow_nonref;
my %supported= map {$_=>1} qw(JGRAFT AT COPY MOVE EXPR NODE TEMP STASH CONST CAP
   FAIL LENGTH SLICE LOCAL AND OR NOT CASTBOOL CASTNUM CASTSTR ADD MUL SUB DIV MOD);
sub supported {
   my $v=shift;
   return 0 if blessed($v) && $v->isa('JGraft::_Node') && !$supported{$v->_name};
   return !grep !supported($_), @$v if ref($v) eq 'ARRAY';
   return !grep !supported($v->{$_}), grep $_ ne '_form', keys %$v
      if ref($v) eq 'HASH' || blessed($v) && $v->isa('JGraft::_Node');
   return 1;
}
sub cases {
   my ($group,$prefix)=@_;
   if (exists $group->{tests}) {
      cases($_,$prefix.$group->{name}.' / ') for @{$group->{tests}};
      return;
   }
   my $case=$group;
   my $name=$prefix.$case->{name};
   my $before=$json->encode([$case->{input},$case->{jgraft}]);
   my $graft=eval { JGraft::jgparse($case->{jgraft}) };
   if ($@) {
      ok($case->{errors}{INVALID_GRAFT}, "$name: static rejection") or diag "$@";
      return;
   }
   unless (supported($graft)) { SKIP: { skip "$name: uses an operation outside this batch",1 } return }
   my $exec=JGraft::Exec->new(jgraft=>$graft, undo=>1, exists $case->{limits}? (limits=>$case->{limits}):());
   my @out=$exec->apply($case->{input});
   if ($exec->error) {
      ok($case->{errors}{$exec->error}, "$name: permitted failure") or diag "$exec";
   }
   elsif ($case->{errors}{RESOURCE_LIMIT}) { fail "$name: required resource failure" }
   else {
      ok(exists $case->{output}, "$name: success permitted");
      is($json->encode($out[0]),$json->encode($case->{output}), "$name: output");
   }
   is($json->encode([$case->{input},$case->{jgraft}]),$before,"$name: input and graft preserved");
   my $undo=$exec->undo;
   my $data=$json->decode($json->encode($undo->to_json_data));
   my $restore=JGraft::Exec->new(jgraft=>$data);
   my @restored=$restore->apply($exec->output);
   ok($restore->success,"$name: undo succeeds") or diag "$restore", explain($data);
   is($json->encode($restore->output),$json->encode($case->{input}),"$name: undo restores input");
}
for my $file (qw(01-copy 02-move 16-jgraft-namespaces 25-fail 28-math 33-and-or-not)) {
   open my $fh,'<:raw',"jgraft-spec/conformance/$file.json" or die $!;
   my $data=JSON::PP->new->utf8->decode(do {local $/; <$fh>});
   cases($data,'');
}
done_testing;
