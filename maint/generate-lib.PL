use strict;
use warnings;
use File::Basename 'dirname';
use File::Path 'mkpath';
use File::Temp 'tempfile';
require './maint/JGraftBuild.pm';

my ($target, $source)= @ARGV;
defined $source or die "Usage: $0 target source [dependencies]\n";
open my $in, '<', $source or die "open($source): $!\n";
binmode $in;
my $text= do { local $/; <$in> };
close $in or die "close($source): $!\n";
$text= JGraftBuild::filter_source($text, $], $source);

my $dir= dirname($target);
mkpath($dir) unless -d $dir;
my ($out, $temp)= tempfile('.jgraft-XXXXXX', DIR => $dir, UNLINK => 1);
binmode $out;
print $out $text or die "write($temp): $!\n";
close $out or die "close($temp): $!\n";
rename $temp, $target or die "rename($temp, $target): $!\n";
