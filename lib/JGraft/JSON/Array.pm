package JGraft::JSON::Array;
# VERSION
# ABSTRACT: JSON array storage retaining whitespace and comments
use strict;
use warnings;
use JGraft::JSON::_Layout 'same_origin';

# Storage: { items=>[values], doc=>document, open=>token index, mod=>modified }.
# doc and open exist only for decoded arrays with retained layout; the encoder
# compares the items with the original tokens (see JGraft::JSON::_Layout).
# Resource accounting shares JGraft::JSON::Object's execution context.

sub _exec { $JGraft::JSON::Object::EXEC }
sub TIEARRAY { bless {items=>[]},shift }
sub FETCH { $_[0]{items}[$_[1]] }
sub FETCHSIZE { scalar @{$_[0]{items}} }
sub EXISTS { $_[1]<@{$_[0]{items}} }
sub EXTEND {}
sub STORE {
   my ($s,$i,$v)=@_;
   my $n=@{$s->{items}};
   return $s->_insert($n,[(undef) x ($i-$n),$v]) if $i>=$n;
   $s->{mod}=1;
   $s->{items}[$i]=$v;
}
sub STORESIZE {
   my ($s,$n)=@_;
   my $size=@{$s->{items}};
   if ($n<$size) { $s->_remove($n,$size-$n) }
   elsif ($n>$size) { $s->_insert($size,[(undef) x ($n-$size)]) }
}
sub CLEAR { my $s=shift; $s->{items}=[]; $s->{mod}=1 }
sub PUSH { my $s=shift; $s->_insert(scalar @{$s->{items}},[@_]); scalar @{$s->{items}} }
sub UNSHIFT { my $s=shift; $s->_insert(0,[@_]); scalar @{$s->{items}} }
sub POP { my $s=shift; @{$s->{items}}? ($s->_remove($#{$s->{items}},1))[0] : undef }
sub SHIFT { my $s=shift; @{$s->{items}}? ($s->_remove(0,1))[0] : undef }
sub DELETE {
   my ($s,$i)=@_;
   my $n=@{$s->{items}};
   return undef if $i>=$n;
   return $s->POP if $i==$n-1;
   my $v=$s->{items}[$i];
   $s->STORE($i,undef);
   return $v;
}
sub SPLICE {
   my $s=shift;
   my $size=@{$s->{items}};
   my $off=@_? shift : 0;
   $off+=$size if $off<0;
   $off=0 if $off<0;
   $off=$size if $off>$size;
   my $len=@_? shift : $size-$off;
   $len+=$size-$off if $len<0;
   $len=0 if $len<0;
   $len=$size-$off if $off+$len>$size;
   my @removed=$s->_remove($off,$len);
   $s->_insert($off,[@_]) if @_;
   return wantarray? @removed : $removed[-1];
}
sub _remove {
   my ($s,$off,$len)=@_;
   return unless $len;
   my $exec=_exec();
   $exec->_tick(1+@{$s->{items}}-$off) if $exec;
   $s->{mod}=1;
   return splice @{$s->{items}},$off,$len;
}
sub _insert {
   my ($s,$pos,$values)=@_;
   return unless @$values;
   my $exec=_exec();
   if ($exec) {
      $exec->_tick(1+@{$s->{items}}-$pos+@$values);
      $exec->_reserve(0,16*@$values,0);
   }
   $s->{mod}=1;
   splice @{$s->{items}},$pos,0,@$values;
   return;
}
sub clone {
   my ($s,$map)=@_;
   my $n=@{$s->{items}};
   if (my $exec=_exec()) {
      $exec->_tick(1+$n*($s->{doc}?2:1));
      $exec->_allocation(128+16*$n);
   }
   my @out;
   my $copy=tie @out,ref($s);
   $copy->{items}=$map? [map $map->($_),@{$s->{items}}] : [@{$s->{items}}];
   if ($s->{doc}) {
      @{$copy}{qw(doc open mod)}=@{$s}{qw(doc open mod)};
      # A mapped copy stays unmodified while its values are interchangeable.
      if ($map && !$copy->{mod}) {
         for my $i (0..$n-1) {
            next if same_origin($s->{items}[$i],$copy->{items}[$i]);
            $copy->{mod}=1;
            last;
         }
      }
   }
   return \@out;
}

=head1 SYNOPSIS

  my $json= JGraft::JSON->new(preserve_whitespace => 1, comments => 1);
  my $data= $json->decode($text);
  if (my $tie= tied @$array) {
     my $copy= $tie->clone if $tie->can('clone');
  }

=head1 DESCRIPTION

Arrays decoded by L<JGraft::JSON> while retaining whitespace or comments are
unblessed array references tied to this class. Other arrays stay ordinary.

The array refers to its position in the original document text. While it is
unmodified, encoding can reproduce its original text directly. After changes,
the encoder recognizes original elements: containers by their position,
decoded numbers and wrapped strings by their recorded offset, and other values
by comparing them with the original tokens in order. Recognized elements keep
their whitespace and comments. Unrecognized elements (new or replacement
values) copy the whitespace (never comments) of the previous element. The first
element always uses the whitespace following the opening bracket.

Ordinary array operations work, including C<splice>, though tied access is
slower than a native array.

=method clone

  my $ref= tied(@$array)->clone($map);

Return a new array reference tied to the same class, with the same layout. The
optional callback maps each element value. L<JGraft::JSON::Object> implements
the same interface for objects.

=for Pod::Coverage TIEARRAY FETCH FETCHSIZE EXISTS EXTEND STORE STORESIZE CLEAR PUSH UNSHIFT POP SHIFT DELETE SPLICE

=cut

1;
