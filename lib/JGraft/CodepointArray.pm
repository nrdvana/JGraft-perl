package JGraft::CodepointArray;
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

# Standalone construction preserves every Unicode codepoint, including lone
# surrogates. Execution's private constructor additionally applies its policy.
sub new {
   no warnings 'utf8';
   my ($class,$text)=@_;
   require Carp;
   defined($text) && !ref($text) or Carp::croak('Expected a Perl string');
   return bless \$text,$class unless utf8::is_utf8($text) || $class eq 'JGraft::CodepointArray::_32';
   my $buffer='';
   for my $cp (unpack('U*',$text)) {
      $cp<=0x10ffff or Carp::croak('Codepoint exceeds Unicode maximum');
      vec($buffer,length($buffer)/4,32)=$cp;
   }
   return bless \$buffer,'JGraft::CodepointArray::_32';
}

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
   return bless \$buffer,$wide?'JGraft::CodepointArray::_32':$class;
}

@JGraft::CodepointArray::_32::ISA=(__PACKAGE__);
sub JGraft::CodepointArray::size { length(${$_[0]}) }
sub JGraft::CodepointArray::at { vec(${$_[0]},$_[1],8) }
sub JGraft::CodepointArray::slice {
   my ($self,$offset,$size)=@_;
   my $buffer=substr($$self,$offset,$size);
   return bless \$buffer,ref($self);
}
sub JGraft::CodepointArray::_literal {
   my ($self,$exec,$text,$position)=@_;
   $text=$text->value if ref($text) eq 'JGraft::JSON::String';
   my $size=length($text);
   return if $position+$size>$self->size;
   return 0 unless $size;
   my $cache=$exec->{regex_literals}{1} ||= {};
   $exec->_tick(length($text)*.001+1);
   my $test=$cache->{$text};
   unless ($test) {
      if (utf8::is_utf8($text)) {
         return unless utf8::downgrade($text,1);
      }
      my $scratch_base=$exec->{scratch_mem};
      local $exec->{scratch_mem}=$scratch_base;
      $exec->_scratch_set($scratch_base,__PACKAGE__->_workspace($text,0));
      my $pattern=__PACKAGE__->_new($exec,$text,'pattern',0,1);
      my $bytes=$$pattern;
      $exec->_reserve(0,128+4*length($bytes)+4*length($text),0);
      $test=$cache->{$text}=$size==1? [$pattern->at(0)] : qr/\G\Q$bytes\E/;
   }
   $exec->_tick($size*.001+1);
   return $self->at($position)==$test->[0]? 1 : undef if ref($test) eq 'ARRAY';
   pos($$self)=$position;
   return $$self =~ /$test/gc ? $size : undef;
}
sub JGraft::CodepointArray::_32::size { length(${$_[0]})/4 }
sub JGraft::CodepointArray::_32::at { vec(${$_[0]},$_[1],32) }
sub JGraft::CodepointArray::_32::slice {
   my ($self,$offset,$size)=@_;
   my $buffer=substr($$self,$offset*4,$size*4);
   return bless \$buffer,ref($self);
}
sub JGraft::CodepointArray::_32::_literal {
   my ($self,$exec,$text,$position)=@_;
   $text=$text->value if ref($text) eq 'JGraft::JSON::String';
   my $size=length($text);
   return if $position+$size>$self->size;
   return 0 unless $size;
   my $cache=$exec->{regex_literals}{4} ||= {};
   $exec->_tick(length($text)*.001+1);
   my $test=$cache->{$text};
   unless ($test) {
      my $scratch_base=$exec->{scratch_mem};
      local $exec->{scratch_mem}=$scratch_base;
      $exec->_scratch_set($scratch_base,__PACKAGE__->_workspace($text,1));
      my $pattern=__PACKAGE__->_new($exec,$text,'pattern',1,1);
      my $bytes=$$pattern;
      $exec->_reserve(0,128+4*length($bytes)+4*length($text),0);
      $test=$cache->{$text}=$size==1? [$pattern->at(0)] : qr/\G\Q$bytes\E/;
   }
   $exec->_tick($size*.001+1);
   return $self->at($position)==$test->[0]? 1 : undef if ref($test) eq 'ARRAY';
   pos($$self)=$position*4;
   return $$self =~ /$test/gc ? $size : undef;
}

=head1 SYNOPSIS

  my $view = JGraft::CodepointArray->new($text);
  my $count = $view->size;
  my $codepoint = $view->at(0);
  my $part = $view->slice(0, $count);

=head1 DESCRIPTION

A read-only packed array of Unicode codepoints. Byte strings use eight-bit
storage; character strings use the internal C<JGraft::CodepointArray::_32>
subclass declared in this file. Both representations are blessed scalar
references; callers must not modify the underlying buffer.

=constructor new

Construct from a Perl string, preserving lone surrogates and noncharacters.
Codepoints above U+10FFFF are rejected. The source string remains unchanged.
This standalone constructor does not require an executor. Execution uses private
construction helpers to apply its codepoint policy and resource accounting.

=method size

Return the number of codepoints.

=method at

Return the numeric codepoint at a nonnegative index. As with Perl's C<vec>,
reading beyond the buffer returns zero; use C<size> to check existence.

=method slice

Return an independent packed view for the supplied offset and length, measured
in codepoints. Offsets and lengths follow Perl's C<substr> semantics. The result
retains the source representation.

=cut

1;
