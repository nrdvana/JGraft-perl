package ExtUtils::PerlVersionFilter;
use strict;
use warnings;
use File::Basename ();
use File::Find ();
use File::Path ();
use File::Temp ();
use Exporter ();

our $VERSION= '0.001';
our @ISA= ('Exporter');
our @EXPORT_OK= qw( filter_source filter_file makefile_args );

=head1 NAME

ExtUtils::PerlVersionFilter - Select version-specific code blocks at build time

=head1 SYNOPSIS

Source, with the newest variant active and older variants commented out:

  #__p5.36__
  use v5.36;
  sub add($x, $y) { $x + $y }
  #__p5.8<5.36__
  #use strict;
  #use warnings;
  #sub add { $_[0] + $_[1] }
  #__pEND__

  #__p<5.10__
  #use MRO::Compat;
  #__pEND__

  #__pSUFFIX__
  use builtin 'true', 'false';     #__p5.36__
  #sub true() { !!1 } sub false() { !!0 }   #__p<5.36__

Makefile.PL:

  require './inc/ExtUtils/PerlVersionFilter.pm';
  WriteMakefile(
     ...,
     ExtUtils::PerlVersionFilter::makefile_args(),
  );

=head1 DESCRIPTION

This module rewrites Perl source so that each marked region has exactly the
variant appropriate for the perl being built for.  It changes nothing but a
leading C<#> on the affected lines, so bytes, newlines, and line numbers of the
generated file match the source.  Installed modules need no source filter or
runtime version dispatch.

=head2 Version conditions

Every marker other than the end marker carries a condition on the perl version:

  #__p5.28__        perl 5.28 or newer
  #__p<5.28__       any perl older than 5.28
  #__p5.10<5.28__   perl 5.10 or newer, but older than 5.28

Versions are written dotted-decimal, C<5.28> or C<5.10.1>, with a missing patch
level meaning zero.  The upper bound is always exclusive.

Code under a condition with no upper bound is written B<live> in the source and
gets a C<#> prefixed when the condition is false.  Code under a condition with
an upper bound is written B<commented>, with C<#> in column one, which is
removed when the condition is true; write C<##> for a line that should remain a
comment.  The unfiltered source is therefore always the variant for the newest
perl.

=head2 Blocks

A block is one or more condition markers, each followed by its branch of
lines, optionally an else marker and its branch, and then an end marker:

  #__p5.28__
  ...
  #__p5.10.1<5.28__
  #...
  #__pELSE__
  #...
  #__pEND__

=over

=item *

Markers start in column one and occupy the whole line (trailing spaces, tabs
and CR are permitted).  Blocks cannot nest.

=item *

Branches must be in strictly decreasing order of lower bound, and must not
overlap.  A later branch is implicitly bounded above by the branch before it, so
C<#__p5.10.1__> could be written above instead of C<#__p5.10.1E<lt>5.28__>;
repeating the bound is permitted for clarity, and is checked.  No version
branch can follow a C<#__pE<lt>X__> branch.

=item *

C<#__pELSE__> begins a final branch which applies whenever no branch before it
did.  After a single C<#__pX__> branch it means exactly C<#__pE<lt>X__>; which
to write is a matter of taste, the explicit bound being easier to follow when
the branches are long.  It is only permitted in a block whose first branch is
live, and nothing can follow it.

=item *

At most one branch applies to any perl.  Only the first branch can be live in
the source, and only if it has no upper bound; all lines of every other branch
must start with C<#> (except blank lines).

=item *

If a live first branch contains any nonblank line and does not apply to the
target perl, some other branch must apply, or filtering dies.  This prevents
silently building a module with code missing on a perl that nobody wrote a
variant for.  To deliberately have nothing on older perls, add an empty branch:

  #__p5.36__
  use builtin 'true';
  #__pELSE__
  #__pEND__

A block whose branches all start commented simply has no branch enabled when
none applies.

=back

=head2 One-line markers

One-line markers are disabled unless the file enables them with a directive on
a line of its own, starting in column one and outside any block.  They are then
recognized from that line to the end of the file:

  #__pSUFFIX__

A condition marker at the end of a line of code, separated from it by
whitespace, then applies to that line alone, and needs no end marker:

     $x= frobnicate($x);     #__p5.28__
  #   $x= 0+$x;               #__p<5.28__

The same live/commented rule applies: a line whose condition has an upper bound
must start with C<#> in column one.  A live line is commented out on perls where
its condition is false; this never dies.  One-line markers cannot be used
inside a block.

Be aware that the filter does not parse Perl.  It does skip POD, but it will
act on a line that ends with a marker inside a here-doc or other multi-line
string.  Anything other than whitespace following the marker on the line
prevents it from being recognized.

=head2 Marker-like text

The filter never looks at the middle of a line, so markers can be mentioned
freely in comments and strings.  To catch typos, these are rejected:

=over

=item *

A line starting in column one with something that looks like a marker
(C<#__p> followed by a digit, C<E<lt>>, C<ELSE>, C<END> or C<SUFFIX>) which is
not a valid one.  This applies everywhere, including POD.

=item *

An indented line beginning that way, outside of POD.  Within POD (from any
C<=command> paragraph to C<=cut>) indented examples of markers are left alone,
while markers in column one remain in effect.

=item *

Once one-line markers are enabled, a line outside of POD whose last word looks
like a marker but is not a valid one.

=back

=head1 FUNCTIONS

All functions are exportable on request.

=head2 filter_source

  $filtered= filter_source($source, $perl_version, $name);

Return C<$source> filtered for C<$perl_version>, which defaults to C<$]>.  The
version may be numeric like C<$]> (C<5.028001>) or dotted with a leading C<v>
or two dots (C<v5.28>, C<5.28.1>).  C<$name> is used in error messages, which
have the form C<"$name:$line: $message\n">.  Dies on any malformed block.

=cut

# Normalize a version to the integer major*1e6 + minor*1e3 + patch
sub _dotted_vnum {
   my ($major, $minor, $patch)= @_;
   return $major * 1_000_000 + ($minor || 0) * 1_000 + ($patch || 0);
}

sub _perl_vnum {
   my $v= shift;
   $v= $] unless defined $v;
   return _dotted_vnum($1, $2, $3)
      if $v =~ /^v(\d+)(?:\.(\d+)(?:\.(\d+))?)?\z/ || $v =~ /^(\d+)\.(\d+)\.(\d+)\z/;
   $v =~ /^\d+(?:\.\d+)?\z/ or die "Invalid perl version '$v'\n";
   my ($major, $frac)= split /\./, sprintf '%.6f', $v;
   return _dotted_vnum($major, substr($frac, 0, 3), substr($frac, 3, 3));
}

sub _vnum_str {
   my $v= shift;
   return join '.', int($v / 1_000_000), int($v / 1_000) % 1_000, $v % 1_000;
}

# Condition "LO", "LO<HI", or "<HI".  Captures: lo, hi (of LO<HI), hi (of <HI)
my $VER= qr/\d+\.\d+(?:\.\d+)?/;
my $COND= qr/(?:($VER)(?:<($VER))?|<($VER))/;
my $EOL= qr/[ \t]*(?:\r?\n)?\z/;
my $LOOKALIKE= qr/#__p(?:\d|<|END|ELSE|SUFFIX)/;

# Returns (lo, hi) as version integers; hi is undef when unbounded
sub _cond_range {
   my ($lo, $hi)= @_;
   return (defined $lo? _dotted_vnum(split /\./, $lo) : 0,
           defined $hi? _dotted_vnum(split /\./, $hi) : undef);
}

sub filter_source {
   my ($source, $perl, $name)= @_;
   $name= '<source>' unless defined $name;
   $perl= _perl_vnum($perl);
   # Block state: $branch counts branches seen (0 = outside a block), $start is
   # the block's first line, $live whether its first branch is live code and
   # $live_lines how many nonblank lines that has, $active whether the current
   # branch applies to $perl, and $matched whether any branch has.
   my ($branch, $start, $live, $live_lines, $active, $matched, $prev_lo)= (0);
   # $suffix is set once one-line markers are enabled; $in_pod tracks POD, where
   # they are never recognized and indented marker-like text is permitted.
   my ($line, $output, $suffix, $in_pod)= (0, '', 0, 0);
   for my $text (split /(?<=\n)/, $source) {
      ++$line;
      my $error;
      $in_pod= $1 ne 'cut' if $text =~ /^=([a-zA-Z]\w*)/;
      if ($text =~ /^#__p${COND}__$EOL/) {
         my ($lo, $hi)= _cond_range($1, defined $2? $2 : $3);
         if (defined $hi && $hi <= $lo) {
            $error= 'empty version range';
         }
         elsif (!$branch) {
            ($start, $live, $live_lines, $matched)= ($line, !defined $hi, 0, 0);
         }
         elsif ($lo >= $prev_lo) {
            $error= 'version markers must appear in decreasing order (blocks cannot nest)';
         }
         elsif (defined $hi && $hi > $prev_lo) {
            $error= 'version range overlaps the previous branch';
         }
         else {
            $hi= $prev_lo unless defined $hi;
         }
         ++$branch;
         $prev_lo= $lo;
         $active= $perl >= $lo && (!defined $hi || $perl < $hi);
         $matched ||= $active;
      }
      elsif ($text =~ /^#__pELSE__$EOL/) {
         if (!$branch) {
            $error= 'else marker must follow a version branch';
         }
         elsif (!$live) {
            $error= 'else marker requires a first branch with no upper version bound';
         }
         elsif (!$prev_lo) {
            $error= 'else marker must be the last branch';
         }
         ++$branch;
         $prev_lo= 0;
         $active= !$matched;
         $matched= 1;
      }
      elsif ($text =~ /^#__pEND__$EOL/) {
         if (!$branch) {
            $error= 'end marker must follow a version branch';
         }
         elsif ($live && $live_lines && !$matched) {
            $error= "no branch of the version block at line $start applies to perl "
               . _vnum_str($perl);
         }
         $branch= 0;
      }
      elsif ($text =~ /^#__pSUFFIX__$EOL/) {
         $error= 'suffix directive inside a version block' if $branch;
         $suffix= 1;
      }
      elsif ($suffix && !$in_pod && $text =~ /^(.*?\S)[ \t]+#__p${COND}__$EOL/) {
         my ($code, $lo, $hi)= ($1, _cond_range($2, defined $3? $3 : $4));
         my $applies= $perl >= $lo && (!defined $hi || $perl < $hi);
         (my $bare= $code) =~ s/^#//;
         if ($bare !~ /\S/) {
            $error= 'malformed version marker';
         }
         elsif ($branch) {
            $error= 'one-line version marker inside a version block';
         }
         elsif (defined $hi && $hi <= $lo) {
            $error= 'empty version range';
         }
         elsif (!defined $hi) {
            $text= '#'.$text unless $applies;
         }
         elsif ($text !~ /^#/) {
            $error= 'line with an upper version bound must start with #';
         }
         elsif ($applies) {
            $text =~ s/^#//;
         }
      }
      elsif ($text =~ /^$LOOKALIKE/
         || !$in_pod && ($text =~ /^[ \t]+$LOOKALIKE/ || $suffix && $text =~ /[ \t]$LOOKALIKE\S*$EOL/)
      ) {
         $error= 'malformed version marker';
      }
      elsif ($branch == 1 && $live) {
         ++$live_lines if $text =~ /\S/;
         $text= '#'.$text unless $active;
      }
      elsif ($branch) {
         $error= 'lines of a branch after the first, or with an upper version bound, must start with #'
               . ' (except blank lines)'
            unless $text =~ /^#/ || $text =~ /^[ \t\r\n]*\z/;
         $text =~ s/^#// if $active;
      }
      die "$name:$line: $error\n" if $error;
      $output .= $text;
   }
   die "$name:$line: unterminated version block starting at line $start\n" if $branch;
   return $output;
}

=head2 filter_file

  filter_file($source_path, $target_path, $perl_version);

Filter one file into another, creating the target directory as needed.  The
source is validated before the target is touched, and the target is replaced
atomically.

=cut

sub filter_file {
   my ($source, $target, $perl)= @_;
   open my $in, '<', $source or die "open($source): $!\n";
   binmode $in;
   my $text= do { local $/; <$in> };
   close $in or die "close($source): $!\n";
   $text= '' unless defined $text;
   $text= filter_source($text, $perl, $source);

   my $dir= File::Basename::dirname($target);
   File::Path::mkpath($dir) unless -d $dir;
   my ($out, $temp)= File::Temp::tempfile('.pvf-XXXXXX', DIR => $dir, UNLINK => 1);
   binmode $out;
   print $out $text or die "write($temp): $!\n";
   close $out or die "close($temp): $!\n";
   # tempfile creates 0600; give the result ordinary umask-derived permissions
   chmod 0666 & ~umask, $temp;
   rename $temp, $target or die "rename($temp, $target): $!\n";
   return 1;
}

=head2 makefile_args

  WriteMakefile(..., makefile_args(%options));

Return C<PM> and C<PL_FILES> arguments for L<ExtUtils::MakeMaker> which build
every matching file under C<lib> directly into C<$(INST_LIB)> through the
filter, instead of copying them with C<pm_to_blib>.  Each target depends on its
source, this module, and the Makefile, so it is regenerated when the filter or
the interpreter changes.  Options:

=over

=item lib

Source directory.  Default C<lib>.

=item match

Regex selecting file names to process.  Default C<qr/\.(?:pm|pod)\z/>.

=item script

The program MakeMaker runs as C<script target source ...>.  Defaults to this
module file, which filters C<source> to C<target> for the running perl when
executed as a program.

=back

=cut

# PL_FILES builds directly into blib. Explicit dependencies avoid pm_to_blib's
# same-size/mtime shortcut, and rebuild when the interpreter or filter changes.
sub makefile_args {
   my %opt= @_;
   my $lib= defined $opt{lib}? $opt{lib} : 'lib';
   my $match= $opt{match} || qr/\.(?:pm|pod)\z/;
   (my $self= __FILE__) =~ s{^\./}{};
   my $script= defined $opt{script}? $opt{script} : $self;
   my %targets;
   File::Find::find({ no_chdir => 1, wanted => sub {
      return unless -f $_ && $_ =~ $match;
      my $source= $File::Find::name;
      (my $target= $source) =~ s{^\Q$lib\E/}{\$(INST_LIB)/};
      $targets{$target}= [$source, ($script eq $self? () : $self), '$(FIRST_MAKEFILE)'];
   } }, $lib);
   return (
      PM => {},
      PL_FILES => { $script => \%targets },
   );
}

# Run as a program by the PL_FILES rule: target source [dependencies...]
unless (caller) {
   my ($target, $source)= @ARGV;
   defined $source or die "Usage: $0 target source [dependencies]\n";
   filter_file($source, $target, $]);
}

1;
