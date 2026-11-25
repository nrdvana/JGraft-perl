use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
require './inc/ExtUtils/PerlVersionFilter.pm';
my $filter= \&ExtUtils::PerlVersionFilter::filter_source;

my $source= <<'PERL';
before
#__p5.28__
sub version { 'modern' }
#__p<5.28__
#sub version { 'legacy' }
## A legacy comment

#__pEND__
after
PERL
my $legacy= <<'PERL';
before
#__p5.28__
#sub version { 'modern' }
#__p<5.28__
sub version { 'legacy' }
# A legacy comment

#__pEND__
after
PERL
is($filter->($source, 5.008009), $legacy, 'legacy branch selected');
is($filter->($source, 5.006002), $legacy, 'open lower bound applies to any older perl');
is($filter->($source, 5.027999), $legacy, 'workarounds apply below 5.28');
is($filter->($source, 5.028), $source, 'modern branch starts at 5.28');
is($filter->($source, 5.040001), $source, 'modern source unchanged');
is($filter->($source), $filter->($source, $]), 'defaults to the running perl');
is($filter->('', 5.008009), '', 'empty source');
is($filter->("plain\r\ntext", 5.008009), "plain\r\ntext", 'unmarked bytes preserved');
for my $plain ("#__PACKAGE__->x;\n #__private\n#__end__\n", "see the #__p5.28__ and #__pEND__ markers\n",
   "#__print\nx #__pEN\n",
) {
   is($filter->($plain, 5.008009), $plain, 'unrelated text preserved');
}
(my $crlf_source= $source) =~ s/\n/\r\n/g;
(my $crlf_legacy= $legacy) =~ s/\n/\r\n/g;
is($filter->($crlf_source, 5.008009), $crlf_legacy, 'CRLF preserved');

# Render a list of lines, replacing the lines at the given indexes
sub edit {
   my ($lines, %edit)= @_;
   join '', map { exists $edit{$_}? $edit{$_} : $lines->[$_] } 0..$#$lines;
}

subtest 'multiple branches' => sub {
   my @body= ("#__p5.36__\n", "A\n", "\n", "#__p5.20.2<5.36__\n", "#B\n", "##b\n",
      "#__p5.10__\n", "#C\n", "#__p5.8.9<5.10__\n", "#__PACKAGE__->D;\n", "#__pEND__\n");
   my $src= edit(\@body);
   my @off= (1 => "#A\n", 2 => "#\n");
   for my $case (
      ['5.036',    $src],
      ['5.040002', $src],
      ['v5.36',    $src],
      ['5.36.0',   $src],
      ['5.035011', edit(\@body, @off, 4 => "B\n", 5 => "#b\n")],
      ['5.020002', edit(\@body, @off, 4 => "B\n", 5 => "#b\n")],
      ['5.20.2',   edit(\@body, @off, 4 => "B\n", 5 => "#b\n")],
      ['5.020001', edit(\@body, @off, 7 => "C\n")],
      ['5.010',    edit(\@body, @off, 7 => "C\n")],
      ['v5.10',    edit(\@body, @off, 7 => "C\n")],
      ['5.008009', edit(\@body, @off, 9 => "__PACKAGE__->D;\n")],
   ) {
      is($filter->($src, $case->[0]), $case->[1], "perl $case->[0]");
   }
   is($filter->($src, 5.02), $filter->($src, '5.020000'), 'numeric version loses no trailing zeros');
   ok(!eval { $filter->($src, 5.008008, 'fixture.pm'); 1 }, 'dies below every branch');
   like($@, qr/^fixture\.pm:11: no branch of the version block at line 1 applies to perl 5\.8\.8\n/,
      'error names the block and perl');
};

subtest 'unmatched blocks' => sub {
   my $gap= "#__p5.28__\nA\n#__p5.10<5.20__\n#B\n#__pEND__\n";
   ok(!eval { $filter->($gap, 5.022, 'fixture.pm'); 1 }, 'dies in a gap between branches');
   like($@, qr/^fixture\.pm:5: no branch of the version block at line 1 applies to perl 5\.22\.0\n/, 'gap error');
   is($filter->($gap, 5.016), "#__p5.28__\n#A\n#__p5.10<5.20__\nB\n#__pEND__\n", 'matches below the gap');
   ok(!eval { $filter->("#__p5.36__\nx\n#__pEND__\n", 5.028, 'fixture.pm'); 1 }, 'lone live branch dies when inactive');
   is($filter->("#__p5.36__\nx\n#__pEND__\n", 5.036), "#__p5.36__\nx\n#__pEND__\n", 'lone live branch active');
   is($filter->("#__p5.36__\nx\n#__p<5.36__\n#__pEND__\n", 5.028), "#__p5.36__\n#x\n#__p<5.36__\n#__pEND__\n",
      'empty alternate branch permits removing live code');
   is($filter->("#__p5.28__\n\n#__p5.10<5.20__\n#B\n#__pEND__\n", 5.022), "#__p5.28__\n#\n#__p5.10<5.20__\n#B\n#__pEND__\n",
      'blank live branch needs no alternate');
   my $bounded= "#__p5.10<5.20__\n#B\n#__p<5.10__\n#C\n#__pEND__\n";
   is($filter->($bounded, 5.036), $bounded, 'commented block unchanged above its range');
   is($filter->($bounded, 5.012), "#__p5.10<5.20__\nB\n#__p<5.10__\n#C\n#__pEND__\n", 'bounded first branch');
   is($filter->($bounded, 5.008), "#__p5.10<5.20__\n#B\n#__p<5.10__\nC\n#__pEND__\n", 'branch below bounded first branch');
   my $range= "#__p5.10<5.20__\n#B\n#__pEND__\n";
   is($filter->($range, 5.008), $range, 'commented block unchanged below its range');
   is($filter->($range, 5.020), $range, 'upper bound is exclusive');
   is($filter->($range, 5.019011), "#__p5.10<5.20__\nB\n#__pEND__\n", 'just below upper bound');
};

subtest 'else branch' => sub {
   my @body= ("#__p5.28__\n", "A\n", "#__p5.10<5.20__\n", "#B\n", "#__pELSE__\n", "#C\n", "## c\n", "#__pEND__\n");
   my $src= edit(\@body);
   is($filter->($src, 5.028), $src, 'first branch');
   is($filter->($src, 5.012), edit(\@body, 1 => "#A\n", 3 => "B\n"), 'middle branch');
   is($filter->($src, 5.022), edit(\@body, 1 => "#A\n", 5 => "C\n", 6 => "# c\n"), 'else covers a gap');
   is($filter->($src, 5.006), edit(\@body, 1 => "#A\n", 5 => "C\n", 6 => "# c\n"), 'else covers older perls');
   (my $explicit= $source) =~ s/^#__p<5\.28__$/#__pELSE__/m;
   (my $explicit_legacy= $legacy) =~ s/^#__p<5\.28__$/#__pELSE__/m;
   is($filter->($explicit, 5.008009), $explicit_legacy, 'else equals explicit upper bound');
   is($filter->($explicit, 5.028), $explicit, 'else inactive on modern perl');
   is($filter->("#__p5.36__\nx\n#__pELSE__\n#__pEND__\n", 5.028), "#__p5.36__\n#x\n#__pELSE__\n#__pEND__\n",
      'empty else permits removing live code');
};

subtest 'one-line markers' => sub {
   my @body= ("#__pSUFFIX__ \n", "   new();  #__p5.36__\n", "#   mid();\t#__p5.10<5.36__  \r\n", "#old(); #__p<5.10__\n",
      "## note   #__p<5.10__\n", "plain # comment\n", "last() #__p5.10.1__");
   my $src= edit(\@body);
   is($filter->($src, 5.036), $src, 'newest perl leaves source unchanged');
   is($filter->($src, 5.010001), edit(\@body, 1 => "#   new();  #__p5.36__\n", 2 => "   mid();\t#__p5.10<5.36__  \r\n"),
      'range line enabled');
   is($filter->($src, 5.010), edit(\@body, 1 => "#   new();  #__p5.36__\n", 2 => "   mid();\t#__p5.10<5.36__  \r\n",
      6 => "#last() #__p5.10.1__"), 'live line without newline disabled');
   is($filter->($src, 5.008009), edit(\@body, 1 => "#   new();  #__p5.36__\n", 3 => "old(); #__p<5.10__\n",
      4 => "# note   #__p<5.10__\n", 6 => "#last() #__p5.10.1__"), 'live lines disabled without an alternate');

   (my $disabled= $src) =~ s/^.*\n//;
   $disabled .= "\nbad(); #__p5.28_\ncode(); #__p<5.28__\nx(); #__pEND__\n";
   is($filter->($disabled, 5.008009), $disabled, 'ignored unless enabled');
   my $late= "a(); #__p5.36__\n#__pSUFFIX__\nb(); #__p5.36__\n";
   is($filter->($late, 5.008009), "a(); #__p5.36__\n#__pSUFFIX__\n#b(); #__p5.36__\n", 'enabled from the directive onward');
   my $text= "#__pSUFFIX__\nsee C<#__p5.36__>\nx(); #__p5.36__ .\ny();#__p5.36__\nmention #__p5.28_ here\n";
   is($filter->($text, 5.008009), $text, 'marker must be the last word of the line');
};

subtest 'POD' => sub {
   my $pod= "#__pSUFFIX__\n=head1 X\n\n  #__p5.36__\n  code  #__p5.36__\n  #__pEND__\n  #__p5.28_\n\ntext #__p<5.10__\n\n=cut\n";
   is($filter->($pod, 5.008009), $pod, 'indented and one-line markers ignored in POD');
   is($filter->("$pod\nx(); #__p5.36__\n", 5.008009), "$pod\n#x(); #__p5.36__\n", 'one-line markers resume after =cut');
   is($filter->("=pod\n\n#__p5.36__\nnew\n#__pELSE__\n#old\n#__pEND__\n", 5.008009),
      "=pod\n\n#__p5.36__\n#new\n#__pELSE__\nold\n#__pEND__\n", 'column-one block markers apply in POD');
   ok(!eval { $filter->("=pod\n\n#__p5.28_\n", 5.028, 'fixture.pm'); 1 }, 'column-one typo rejected in POD');
   like($@, qr/^fixture\.pm:3: malformed version marker/, 'error identifies source and line');
};

for my $case (
   ['orphan end', "#__pEND__\n", 'end marker must follow'],
   ['nested block', "#__p5.28__\n#__p5.28__\n", 'version markers must appear in decreasing order'],
   ['increasing versions', "#__p5.8__\n#__p5.28__\n#__pEND__\n", 'version markers must appear in decreasing order'],
   ['increasing patch', "#__p5.10__\n#__p5.10.1__\n#__pEND__\n", 'version markers must appear in decreasing order'],
   ['equal versions', "#__p5.10.0__\n#__p5.10__\n#__pEND__\n", 'version markers must appear in decreasing order'],
   ['branch after open lower bound', "#__p5.28__\n#__p<5.28__\n#__p<5.10__\n", 'version markers must appear in decreasing order'],
   ['overlapping branch', "#__p5.28__\n#__p<5.30__\n#__pEND__\n", 'version range overlaps the previous branch'],
   ['overlapping range', "#__p5.28__\n#__p5.10<5.28.1__\n#__pEND__\n", 'version range overlaps the previous branch'],
   ['orphan else', "#__pELSE__\n#__pEND__\n", 'else marker must follow a version branch'],
   ['else in commented block', "#__p5.10<5.28__\n#__pELSE__\n#__pEND__\n", 'else marker requires a first branch with no upper'],
   ['duplicate else', "#__p5.28__\n#__pELSE__\n#__pELSE__\n#__pEND__\n", 'else marker must be the last branch'],
   ['else after open lower bound', "#__p5.28__\n#__p<5.28__\n#__pELSE__\n#__pEND__\n", 'else marker must be the last branch'],
   ['branch after else', "#__p5.28__\n#__pELSE__\n#__p5.10__\n#__pEND__\n", 'version markers must appear in decreasing order'],
   ['active else code', "#__p5.28__\n#__pELSE__\ncode\n#__pEND__\n", 'lines of a branch after the first, or with an upper version bound, must start'],
   ['one-line else', "#__pSUFFIX__\nx(); #__pELSE__\n", 'malformed version marker'],
   ['malformed else', "#__p5.28__\n#__pELSE_\n", 'malformed version marker'],
   ['suffix directive in block', "#__p5.28__\n#__pSUFFIX__\n#__pELSE__\n#__pEND__\n", 'suffix directive inside a version block'],
   ['malformed suffix directive', "#__pSUFFIX\n", 'malformed version marker'],
   ['indented suffix directive', "  #__pSUFFIX__\n", 'malformed version marker'],
   ['empty range', "#__p5.28<5.28__\n#__pEND__\n", 'empty version range'],
   ['inverted one-line range', "#__pSUFFIX__\n#x(); #__p5.28<5.10__\n", 'empty version range'],
   ['missing end', "#__p5.28__\n#__p<5.28__\n", 'unterminated version block starting at line 1'],
   ['old end marker', "#__p5.28__\n#__p<5.28__\n#__end__\n", 'unterminated version block starting at line 1'],
   ['active legacy code', "#__p5.28__\n#__p<5.28__\ncode\n#__pEND__\n", 'lines of a branch after the first, or with an upper version bound, must start'],
   ['active bounded first branch', "#__p<5.28__\ncode\n#__pEND__\n", 'lines of a branch after the first, or with an upper version bound, must start'],
   ['active bounded line', "#__pSUFFIX__\ncode(); #__p<5.28__\n", 'line with an upper version bound must start with #'],
   ['one-line marker in block', "#__pSUFFIX__\n#__p5.28__\nx(); #__p5.36__\n#__p<5.28__\n#__pEND__\n", 'one-line version marker inside a version block'],
   ['malformed marker', "#__p5.28_\n", 'malformed version marker'],
   ['malformed one-line marker', "#__pSUFFIX__\ncode(); #__p5.28_\n", 'malformed version marker'],
   ['trailing text', "#__p5.28__ modern\n", 'malformed version marker'],
   ['missing minor', "#__p5__\n", 'malformed version marker'],
   ['missing upper version', "#__p5.10<__\n", 'malformed version marker'],
   ['malformed end', "#__p5.28__\n#__pEND_\n", 'malformed version marker'],
   ['indented marker', " #__p5.28__\n", 'malformed version marker'],
   ['indented end', "#__p5.28__\n  #__pEND__\n", 'malformed version marker'],
   ['end after code', "#__pSUFFIX__\n#__p5.28__\nx(); #__pEND__\n", 'malformed version marker'],
   ['commented marker', "#__pSUFFIX__\n# #__p<5.28__\n", 'malformed version marker'],
) {
   for my $perl (5.008009, 5.028) {
      my $ok= eval { $filter->($case->[1], $perl, 'fixture.pm'); 1 };
      ok(!$ok, "$case->[0] rejected for $perl");
      like($@, qr/^fixture\.pm:\d+: \Q$case->[2]\E/, 'error identifies source and line');
   }
}
ok(!eval { $filter->('', 'five'); 1 }, 'invalid perl version rejected');
done_testing;
