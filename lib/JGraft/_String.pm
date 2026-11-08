package JGraft::_String;
# VERSION
# ABSTRACT: Lossless packed codepoint views of Perl strings
use strict;
use warnings;
use Encode ();
use utf8 ();

# Include every plane's terminal noncharacters, without matching ordinary text.
my $problem_class='\\x{D800}-\\x{DFFF}\\x{FDD0}-\\x{FDEF}'.
   join('',map sprintf('\\x{%X}\\x{%X}',($_<<16)+0xfffe,($_<<16)+0xffff),0..16);
my $problems=qr/([$problem_class]|[^\x{0}-\x{10FFFF}])/;

sub _check {
   # Perl 5.8's regex engine otherwise treats the surrogate and U+FFFF
   # encodings as fatal. These are intentional codepoints, checked below.
   no warnings 'utf8';
   my ($class,$exec)=@_;
   my ($text,$kind,$buffer)=@_[2..4];
   $text=$text->value if ref($text) eq 'JGraft::JSON::String';
   return unless utf8::is_utf8($text);
   my $scratch_base=$exec->{scratch_mem};
   local $exec->{scratch_mem}=$scratch_base;
   $exec->_scratch_set($scratch_base,4*length($text)); # Private scan copy on older Perls.
   $exec->_tick(length($text)*.002);
   while ($text =~ /$problems/g) {
      $exec->_tick(1);
      my $cp=ord($1);
      my $index=pos($text)-1;
      $cp<=0x10ffff or $exec->_fail('UNSUPPORTED_GRAFT',sprintf('Codepoint U+%X exceeds Unicode maximum',$cp));
      my $policy=$exec->{options}{codepoint_policy} || 'preserve';
      if (ref($policy) eq 'CODE') {
         # The callback may retain its argument. This value is neither a node
         # location nor an execution-owned container and needs no COW record.
         $exec->_reserve(0,265,1); # Hash, two slots, and index/kind key bytes.
         $policy=$policy->($cp,{index=>$index,kind=>$kind});
         defined($policy) && !ref($policy) && $policy =~ /\A(?:preserve|reject|substitute)\z/
            or $exec->_fail('UNSUPPORTED_GRAFT','codepoint_policy callback must return preserve, reject, or substitute');
      }
      $policy ne 'reject' or $exec->_fail('UNSUPPORTED_GRAFT',sprintf('Rejected codepoint U+%X',$cp));
      vec($$buffer,$index,32)=$cp if $buffer && $policy eq 'preserve';
   }
}
# A caller may cover a temporary view in its own reservation. Default creation
# remains retained, for independent callers and any view that can escape.
sub _workspace {
   my ($class,$text,$wide)=@_;
   $text=$text->value if ref($text) eq 'JGraft::JSON::String';
   return 128+($wide || utf8::is_utf8($text)?8:1)*length($text);
}
sub _new {
   my ($class,$exec)=@_;
   my ($text,$kind)=@_[2,3];
   $text=$text->value if ref($text) eq 'JGraft::JSON::String';
   my $size=length($text);
   my $wide=$_[4] || utf8::is_utf8($text);
   $exec->_tick($size*.002+1);
   $exec->_reserve(0,128+($wide?8:1)*$size,0) unless $_[5];
   my $buffer;
   if ($wide) {
      # CHECK=0 leaves the private source copy intact. Old Encode emits a
      # warning while replacing surrogates/noncharacters; the scan restores
      # their bits. Both the 5.8 and 5.28 warning forms stay local to Encode.
      {
         my $previous=$SIG{__WARN__};
         local $SIG{__WARN__}=sub {
            return if $_[0] =~ /^Malformed UTF-8 character \((?:UTF-16 surrogate|character 0xffff\))/;
            return if $_[0] =~ /^(?:UTF-16 surrogate U\+[0-9A-F]+|Unicode non-character U\+[0-9A-F]+ is not recommended for open interchange) in subroutine entry\b/;
            if (ref($previous) eq 'CODE') { $previous->(@_) }
            elsif (!defined($previous) || $previous ne 'IGNORE') { warn @_ }
         };
         $buffer=Encode::encode('UTF-32BE',$text);
      }
      $class->_check($exec,$text,$kind,\$buffer);
      length($buffer)==4*$size or $exec->_fail('UNSUPPORTED_GRAFT','Invalid Perl character string');
   }
   else { $buffer=$text }
   return bless {buffer=>$buffer,width=>$wide?4:1,size=>$size},$class;
}
sub _at { vec($_[0]{buffer},$_[1],8*$_[0]{width}) }
sub _literal {
   my ($self,$exec,$text,$position)=@_;
   $text=$text->value if ref($text) eq 'JGraft::JSON::String';
   my $size=length($text);
   return if $position+$size>$self->{size};
   return 0 unless $size;
   my $cache=$exec->{regex_literals}{$self->{width}} ||= {};
   $exec->_tick(length($text)*.001+1);
   my $test=$cache->{$text};
   unless ($test) {
      if ($self->{width}==1 && utf8::is_utf8($text)) {
         return unless utf8::downgrade($text,1);
      }
      my $scratch_base=$exec->{scratch_mem};
      local $exec->{scratch_mem}=$scratch_base;
      $exec->_scratch_set($scratch_base,__PACKAGE__->_workspace($text,$self->{width}==4));
      my $pattern=__PACKAGE__->_new($exec,$text,'pattern',$self->{width}==4,1);
      my $bytes=$pattern->{buffer};
      $exec->_reserve(0,128+4*length($bytes)+4*length($text),0);
      $test=$cache->{$text}=$size==1? [$pattern->_at(0)] : qr/\G\Q$bytes\E/;
   }
   $exec->_tick($size*.001+1);
   return $self->_at($position)==$test->[0]? 1 : undef if ref($test) eq 'ARRAY';
   pos($self->{buffer})=$position*$self->{width};
   return $self->{buffer} =~ /$test/gc ? $size : undef;
}

1;
