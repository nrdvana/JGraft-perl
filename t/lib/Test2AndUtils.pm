package Test2AndUtils;
use strict;
use warnings;
use Test2::V0 '!subtest';
use Test2::Tools::Subtest 'subtest_streamed';
use Time::HiRes 'sleep';
use IO::Handle;
use parent 'Test2::V0';

our @EXPORT= (
   @Test2::V0::EXPORT,
   qw( explain unindent pipe_with_data escape_nonprintable unescape_nonprintable cmpthese run_perl test_conformance )
);

# Test2 runs async by default, which messes up the relation between warnings and the test
# that generated them.  Streamed generates output sequentially.
*subtest= \&subtest_streamed;

# Run a fresh copy of the current interpreter against the built modules.
sub run_perl {
   open my $pipe, '-|', $^X, '-Iblib/lib', '-Iblib/arch', @_
      or die "Cannot launch $^X: $!";
   my $output= do { local $/; <$pipe> };
   close $pipe;
   return ($?, defined $output? $output : '');
}

# Run a specification conformance file or an already decoded case/group.
# supported => [operation names] explicitly skips unimplemented operations.
# undo => 0 disables undo round trips (enabled by default).
sub test_conformance {
   my ($source,%options)=@_;
   $_ eq 'supported' || $_ eq 'undo' or die "Unknown conformance option '$_'" for keys %options;
   require JGraft;
   require JGraft::Exec;
   require JSON::PP;
   require Scalar::Util;
   my $suite=$source;
   unless (ref $source) {
      unless (-f $source) {
         SKIP: { skip "$source: conformance fixtures unavailable",1 }
         return;
      }
      open my $fh,'<:raw',$source or die "open($source): $!";
      $suite=JSON::PP->new->utf8->decode(do {local $/; <$fh>});
      close $fh or die "close($source): $!";
   }
   my $config={json=>JSON::PP->new->canonical->allow_nonref,
      undo=>exists $options{undo}? $options{undo} : 1};
   $config->{supported}={map {$_=>1} @{$options{supported}}} if exists $options{supported};
   _conformance_cases($suite,'',$config);
}

sub _conformance_supported {
   my ($value,$supported)=@_;
   my $node=Scalar::Util::blessed($value) && $value->isa('JGraft::_Node');
   return 0 if $node && !$supported->{$value->_name};
   return !grep !_conformance_supported($_,$supported), @$value if ref($value) eq 'ARRAY';
   if (ref($value) eq 'HASH' || $node) {
      my @keys=$node? grep($_ ne '_form', keys %$value) : keys %$value;
      return !grep !_conformance_supported($value->{$_},$supported), @keys;
   }
   return 1;
}

sub _conformance_cases {
   my ($case,$prefix,$config)=@_;
   if (exists $case->{tests}) {
      _conformance_cases($_,$prefix.$case->{name}.' / ',$config) for @{$case->{tests}};
      return;
   }
   my $name=$prefix.$case->{name};
   my $json=$config->{json};
   my $errors=$case->{errors} || {};
   my $before=$json->encode([$case->{input},$case->{jgraft}]);
   my $graft=eval { JGraft::jgparse($case->{jgraft}) };
   my $parse_error=$@;
   if ($parse_error) {
      ok($errors->{INVALID_GRAFT} && !$errors->{RESOURCE_LIMIT},"$name: static rejection")
         or diag "$parse_error";
      is($json->encode([$case->{input},$case->{jgraft}]),$before,"$name: input and graft preserved");
      return;
   }
   if ($config->{supported} && !_conformance_supported($graft,$config->{supported})) {
      SKIP: { skip "$name: uses an unimplemented operation",1 }
      return;
   }
   my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>$config->{undo},
      exists $case->{limits}? (limits=>$case->{limits}):());
   my @out=$exec->apply($case->{input});
   if ($errors->{RESOURCE_LIMIT}) { is($exec->error,'RESOURCE_LIMIT',"$name: required resource failure") }
   elsif ($exec->error) { ok($errors->{$exec->error},"$name: permitted failure") or diag "$exec" }
   else {
      ok(exists $case->{output},"$name: success permitted");
      is($json->encode($out[0]),$json->encode($case->{output}),"$name: output");
   }
   if (exists $case->{logs}) {
      is($json->encode($exec->can('logs')? $exec->logs : []),$json->encode($case->{logs}),"$name: logs");
   }
   is($json->encode([$case->{input},$case->{jgraft}]),$before,"$name: input and graft preserved");
   return unless $config->{undo};
   my $data=$json->decode($json->encode($exec->undo->to_json_data));
   my $restore=JGraft::Exec->new(jgraft=>$data);
   $restore->apply($exec->output);
   ok($restore->success,"$name: undo succeeds") or diag "$restore",explain($data);
   is($json->encode($restore->output),$json->encode($case->{input}),"$name: undo restores input");
}

# Use Data::Printer if available, but fall back to Data::Dumper
eval q{
   use Data::Printer;
   sub explain { Data::Printer::np(@_) }
   1
} or eval q{
   use Data::Dumper;
   sub explain { Data::Dumper->new(\@_)->Terse(1)->Indent(1)->Sortkeys(1)->Dump }
   1
} or die $@;

# Perl didn't get <<~'x' until 5.28, so this lets you write an indented here-block and
# then remove the common indent from all lines.
sub unindent {
   my ($indent)= ($_[0] =~ /^(\s+)/);
   (my $x= $_[0]) =~ s/^$indent//mg;
   $x;
}

# Useful for preparing a pipe with data already loaded in it, and where the write handle
# already has autoflush enabled.
sub pipe_with_data {
   my $data = shift;
   pipe(my $r, my $w) or die "Cannot create pipe: $!";
   $w->autoflush(1);
   $w->print($data) if defined $data;
   return ($r, $w);
}

# Run Benchmark's 'cmpthese' but redirect the output to 'note' and return
# the benchmark hashref from 'timethese'.
# Usage:
#   cmpthese($count, { Name1 => sub { code1 }, ... });  or
#   cmpthese($result, $style);

sub cmpthese {
   require Benchmark;
   Benchmark->import(':hireswallclock');
   my ($benchmarks, $count, $tests, $style);
   if (ref $_[0] ne 'ARRAY' && ref $_[1] eq 'HASH') {
      ($count, $tests, $style)= @_;
      for my $tname (sort keys %$tests) {
         # temporarily capture STDOUT
         my $buffer;
         {  local *main::STDOUT;
            open *main::STDOUT, '>', \$buffer or die "can't capture STDOUT";
            $benchmarks->{$tname}= Benchmark::timethis($count, $tests->{$tname}, $tname, $style);
         }
         note $buffer;
      }
   } else {
      ($benchmarks, $style)= @_;
   }
   # capture STDOUT
   my $buffer;
   {  local *main::STDOUT;
      open *main::STDOUT, '>', \$buffer or die "can't capture STDOUT";
      Benchmark::cmpthese($benchmarks, $style);
   }
   note $buffer;
   return $benchmarks;
}

# Convert data strings to and from C / Perl backslash notation.
# Not exhaustive, just hit the most common cases and hex-escape the rest.

my %escape_to_char = ( "\\" => "\\", r => "\r", n => "\n", t => "\t" );
my %char_to_escape = reverse %escape_to_char;

sub escape_nonprintable {
   my $str = shift;
   $str =~ s/([^\x21-\x7E])/ defined $char_to_escape{$1}? "\\".$char_to_escape{$1} : sprintf("\\x%02X", ord $1) /ge;
   return $str;
}

sub unescape_nonprintable {
   my $str = shift;
   $str =~ s/\\(x([0-9A-F]{2})|.)/ defined $2? chr hex $2 : $escape_to_char{$1} /ge;
   return $str;
}

1;
