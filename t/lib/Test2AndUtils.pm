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
# supported => [operation names] or {name => bool/coderef} filters operations
# and partially implemented forms; predicates receive the parsed node.
# undo => 0 disables undo round trips (enabled by default).
# json => $codec selects an alternate encoder/decoder for fixtures and undo.
sub test_conformance {
   my ($source,%options)=@_;
   $_ eq 'supported' || $_ eq 'undo' || $_ eq 'json' or die "Unknown conformance option '$_'" for keys %options;
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
      my $text=do {local $/; <$fh>};
      $suite=$options{json}?$options{json}->decode($text):_conformance_json($text);
      close $fh or die "close($source): $!";
   }
   my $config={json=>$options{json} || JSON::PP->new->canonical->allow_nonref,
      undo=>exists $options{undo}? $options{undo} : 1};
   if (exists $options{supported}) {
      $config->{supported}=ref($options{supported}) eq 'HASH'? $options{supported}
         : {map {$_=>1} @{$options{supported}}};
   }
   _conformance_cases($suite,'',$config);
}

# Use the same strict transport decoder for fixtures and serialized undo.
sub _conformance_json {
   require JGraft::_JSON;
   my $value=eval { JGraft::_JSON::decode(@_) };
   die "conformance JSON: $@" if $@;
   return $value;
}

sub _conformance_supported {
   my ($value,$supported)=@_;
   my $node=Scalar::Util::blessed($value) && $value->isa('JGraft::_Node');
   if ($node) {
      my $support=$supported->{$value->_name};
      return 0 unless $support;
      return 0 if ref($support) eq 'CODE' && !$support->($value);
   }
   return !grep !_conformance_supported($_,$supported), @$value if ref($value) eq 'ARRAY';
   if (ref($value) eq 'HASH' || $node) {
      my @keys=$node? grep($_ ne '_form', keys %$value) : keys %$value;
      return !grep !_conformance_supported($value->{$_},$supported), @keys;
   }
   return 1;
}

# Compare JSON values by type and value, rather than an encoder's choice of
# integer/exponent spelling. Perl 5.8 may represent equal numbers as IV or NV.
sub _conformance_same {
   my ($a,$b)=@_;
   my $type=JGraft::Util::type_mask($a);
   return 0 unless $type==JGraft::Util::type_mask($b);
   return 1 unless defined $a;
   if (ref($a) eq 'ARRAY') {
      return 0 unless @$a==@$b;
      for my $i (0..$#$a) { return 0 unless _conformance_same($a->[$i],$b->[$i]) }
      return 1;
   }
   if (ref($a) eq 'HASH') {
      return 0 unless keys(%$a)==keys(%$b);
      for my $key (keys %$a) { return 0 unless exists($b->{$key}) && _conformance_same($a->{$key},$b->{$key}) }
      return 1;
   }
   if ($type==JGraft::Util::TYPE_NUMBER() && (ref($a) || ref($b))) {
      return !JGraft::Util::to_rational($a)->bcmp(JGraft::Util::to_rational($b));
   }
   return $a==$b if $type==JGraft::Util::TYPE_NUMBER() || $type==JGraft::Util::TYPE_BOOLEAN();
   return $a eq $b;
}
sub _conformance_compare {
   my ($a,$b,$name,$json)=@_;
   return if ok(_conformance_same($a,$b),$name);
   # Old Test2 table rendering cannot handle raw surrogate scalars on 5.8.
   no warnings 'utf8';
   for my $item (['got',$a],['expected',$b]) {
      my $text=$json->encode($item->[1]);
      $text =~ s/([^\x20-\x7e])/sprintf('\\u{%X}',ord($1))/eg;
      diag "$item->[0]: $text";
   }
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
      _conformance_compare($out[0],$case->{output},"$name: output",$json);
   }
   if (exists $case->{logs}) {
      _conformance_compare($exec->can('logs')? $exec->logs : [],$case->{logs},"$name: logs",$json);
   }
   is($json->encode([$case->{input},$case->{jgraft}]),$before,"$name: input and graft preserved");
   return unless $config->{undo};
   my $data=ref($json) eq 'JSON::PP'?_conformance_json($json->encode($exec->undo->to_json_data))
      :$json->decode($json->encode($exec->undo->to_json_data));
   my $restore=JGraft::Exec->new(jgraft=>$data);
   $restore->apply($exec->output);
   ok($restore->success,"$name: undo succeeds") or diag "$restore",explain($data);
   _conformance_compare($restore->output,$case->{input},"$name: undo restores input",$json);
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
