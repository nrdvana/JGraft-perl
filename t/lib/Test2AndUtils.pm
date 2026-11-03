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
      $suite=_conformance_json(do {local $/; <$fh>});
      close $fh or die "close($source): $!";
   }
   my $config={json=>JSON::PP->new->canonical->allow_nonref,
      undo=>exists $options{undo}? $options{undo} : 1};
   if (exists $options{supported}) {
      $config->{supported}=ref($options{supported}) eq 'HASH'? $options{supported}
         : {map {$_=>1} @{$options{supported}}};
   }
   _conformance_cases($suite,'',$config);
}

# JSON::PP rejects lone-surrogate strings in both data and patterns. Split only
# the conformance outline into raw JSON
# spans so supported leaves still use the normal decoder without altered data.
sub _conformance_json {
   my ($text)=@_;
   my $json=JSON::PP->new->utf8->allow_nonref;
   my $decoded=eval { $json->decode($text) };
   my $error=$@;
   return $decoded unless $error;
   die $error unless $error =~ /surrogate/i;
   my $offset=0;
   my $end=_conformance_json_span(\$text,\$offset);
   substr($text,$end) =~ /\A[ \t\r\n]*\z/ or die 'Trailing data in conformance JSON';
   return _conformance_json_group(\$text,0,$end,$json);
}
sub _conformance_json_space {
   my ($text,$offset)=@_;
   pos($$text)=$$offset;
   $$text =~ /\G[ \t\r\n]*/gc;
   $$offset=pos($$text);
}
sub _conformance_json_span {
   my ($text,$offset)=@_;
   _conformance_json_space($text,$offset);
   my $first=substr($$text,$$offset,1);
   if ($first eq '{' || $first eq '[') {
      ++$$offset;
      _conformance_json_space($text,$offset);
      my $close=$first eq '{'? '}' : ']';
      unless (substr($$text,$$offset,1) eq $close) {
         while (1) {
            if ($first eq '{') {
               substr($$text,$$offset,1) eq '"' or die 'Invalid conformance JSON object key';
               _conformance_json_span($text,$offset);
               _conformance_json_space($text,$offset);
               substr($$text,$$offset,1) eq ':' or die 'Missing conformance JSON colon';
               ++$$offset;
            }
            _conformance_json_span($text,$offset);
            _conformance_json_space($text,$offset);
            last unless substr($$text,$$offset,1) eq ',';
            ++$$offset;
            _conformance_json_space($text,$offset);
         }
      }
      substr($$text,$$offset,1) eq $close or die 'Missing conformance JSON closing delimiter';
      return ++$$offset;
   }
   pos($$text)=$$offset;
   $$text =~ /\G(?:"(?:[^"\\\x00-\x1f]|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null)/gc
      or die 'Invalid conformance JSON value';
   return $$offset=pos($$text);
}
sub _conformance_json_group {
   my ($text,$start,$end,$json)=@_;
   my $offset=$start;
   _conformance_json_space($text,\$offset);
   substr($$text,$offset++,1) eq '{' or die 'Conformance group must be an object';
   my %members;
   _conformance_json_space($text,\$offset);
   while (substr($$text,$offset,1) ne '}') {
      my $key_start=$offset;
      _conformance_json_span($text,\$offset);
      my $key=$json->decode(substr($$text,$key_start,$offset-$key_start));
      _conformance_json_space($text,\$offset);
      ++$offset; # colon already checked by the span scanner
      _conformance_json_space($text,\$offset);
      my $value_start=$offset;
      _conformance_json_span($text,\$offset);
      $members{$key}=[$value_start,$offset];
      _conformance_json_space($text,\$offset);
      last unless substr($$text,$offset,1) eq ',';
      ++$offset;
      _conformance_json_space($text,\$offset);
   }
   unless (exists $members{tests}) {
      my $case=eval { $json->decode(substr($$text,$start,$end-$start)) };
      my $error=$@;
      return $case unless $error;
      die $error unless $error =~ /surrogate/i;
      my $name=$members{name};
      return bless {name=>$json->decode(substr($$text,$name->[0],$name->[1]-$name->[0])),
         reason=>'JSON::PP cannot decode lone-surrogate strings'},'Test2AndUtils::_UnsupportedJSON';
   }
   my %group;
   for my $key (keys %members) {
      next if $key eq 'tests';
      my ($from,$to)=@{$members{$key}};
      $group{$key}=$json->decode(substr($$text,$from,$to-$from));
   }
   $offset=$members{tests}[0];
   substr($$text,$offset++,1) eq '[' or die 'Conformance tests must be an array';
   _conformance_json_space($text,\$offset);
   my @tests;
   while (substr($$text,$offset,1) ne ']') {
      my $from=$offset;
      _conformance_json_span($text,\$offset);
      push @tests,_conformance_json_group($text,$from,$offset,$json);
      _conformance_json_space($text,\$offset);
      last unless substr($$text,$offset,1) eq ',';
      ++$offset;
      _conformance_json_space($text,\$offset);
   }
   $group{tests}=\@tests;
   return \%group;
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

sub _conformance_cases {
   my ($case,$prefix,$config)=@_;
   if (ref($case) eq 'Test2AndUtils::_UnsupportedJSON') {
      SKIP: { skip $prefix.$case->{name}.": ".$case->{reason},1 }
      return;
   }
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
