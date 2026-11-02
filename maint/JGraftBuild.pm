package JGraftBuild;
use strict;
use warnings;
use File::Find ();

# The source always has the modern branch active and the legacy branch commented.
# Change only a leading comment character, preserving bytes and line numbers.
sub filter_source {
   my ($source, $perl, $name)= @_;
   $name= '<source>' unless defined $name;
   my ($state, $line, $output)= ('', 0, '');
   for my $text (split /(?<=\n)/, $source) {
      ++$line;
      my $error;
      if ($text =~ /^#__p5\.28__[ \t]*(?:\r?\n)?\z/) {
         $error= 'nested modern branch' if $state;
         $state= 'modern';
      }
      elsif ($text =~ /^#__p5\.8__[ \t]*(?:\r?\n)?\z/) {
         $error= 'legacy branch must follow a modern branch' unless $state eq 'modern';
         $state= 'legacy';
      }
      elsif ($text =~ /^#__end__[ \t]*(?:\r?\n)?\z/) {
         $error= 'end marker must follow a legacy branch' unless $state eq 'legacy';
         $state= '';
      }
      elsif ($text =~ /^[ \t]*#__/) {
         $error= 'unknown or malformed version marker';
      }
      elsif ($state eq 'modern') {
         $text= '#'.$text if $perl < 5.028;
      }
      elsif ($state eq 'legacy') {
         $error= 'legacy lines must start with # (except blank lines)'
            unless $text =~ /^#/ || $text =~ /^[ \t\r\n]*\z/;
         $text =~ s/^#// if $perl < 5.028;
      }
      die "$name:$line: $error\n" if $error;
      $output .= $text;
   }
   die "$name:$line: unterminated version block\n" if $state;
   return $output;
}

# PL_FILES builds directly into blib. Explicit dependencies avoid pm_to_blib's
# same-size/mtime shortcut, and rebuild when the interpreter or filter changes.
sub makefile_args {
   my %targets;
   File::Find::find({ no_chdir => 1, wanted => sub {
      return unless -f $_ && /\.pm\z/;
      my $source= $File::Find::name;
      (my $target= $source) =~ s{^lib/}{\$(INST_LIB)/};
      $targets{$target}= [$source, 'maint/JGraftBuild.pm', '$(FIRST_MAKEFILE)'];
   } }, 'lib');
   return (
      PM => {},
      PL_FILES => { 'maint/generate-lib.PL' => \%targets },
   );
}

1;
