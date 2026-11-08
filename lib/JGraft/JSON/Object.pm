package JGraft::JSON::Object;
# VERSION
# ABSTRACT: Ordered JSON object storage with duplicate members
use strict;
use warnings;
our $EXEC;

# Storage for {"a": first_a, "b": b, "a": last_a, ...}:
# {
#    tokens => [ 'a', $first_a, 'b', $b, 'a', $last_a, ... ],
#    index  => { a => [0,4], b => 2, ... }, # one offset, or all duplicate offsets
#    seq    => [                         # [previous, next] at each token offset
#       undef, 2,                        # first 'a', offset 0
#       0,     4,                        # 'b',       offset 2
#       2,     ...,                      # last 'a',  offset 4
#       ...
#    ],
#    head=>0, tail=>..., iterator=>..., free=>...,
# }
# Live slots follow seq's previous/next links. Freed slots have undef tokens and
# use seq[offset+1] as the next free offset. Neither list uses reference cycles.
# Encoding visits all live slots; hash iteration yields only each key's last slot.

sub TIEHASH { bless {tokens=>[],index=>{},seq=>[]},shift }
sub _lookup {
   my ($s,$key)=@_;
   $EXEC->_tick(1+length($key)*.001) if $EXEC;
   return $s->{index}{$key};
}
sub _add {
   my ($s,$token,$value)=@_;
   my $i=$s->{free};
   if (defined $i) { $s->{free}=$s->{seq}[$i+1] }
   else {
      $EXEC->_reserve(0,64,0) if $EXEC;
      $i=@{$s->{tokens}};
   }
   @{$s->{tokens}}[$i,$i+1]=($token,$value);
   @{$s->{seq}}[$i,$i+1]=($s->{tail},undef);
   if (defined $s->{tail}) { $s->{seq}[$s->{tail}+1]=$i }
   else { $s->{head}=$i }
   $s->{tail}=$i;
   return $i;
}
sub _unlink {
   my ($s,$i)=@_;
   my ($prev,$next)=@{$s->{seq}}[$i,$i+1];
   if (defined $prev) { $s->{seq}[$prev+1]=$next }
   else { $s->{head}=$next }
   if (defined $next) { $s->{seq}[$next]=$prev }
   else { $s->{tail}=$prev }
   $s->{iterator}=$next if defined($s->{iterator}) && $s->{iterator}==$i;
   @{$s->{tokens}}[$i,$i+1]=(undef,undef);
   @{$s->{seq}}[$i,$i+1]=(undef,$s->{free});
   $s->{free}=$i;
}
# Parsing preserves all occurrences. The common single-member index is a scalar;
# only duplicated keys allocate an array of offsets.
sub _append {
   my ($s,$key,$token,$value)=@_;
   my $offsets=$s->_lookup($key);
   if ($EXEC) {
      if (!defined $offsets) { $EXEC->_reserve(0,64+4*length($key),0) }
      elsif (ref $offsets) { $EXEC->_reserve(0,16,0) }
      else { $EXEC->_allocation(112) }
   }
   my $i=$s->_add($token,$value);
   if (!defined $offsets) { $s->{index}{$key}=$i }
   elsif (ref $offsets) { push @$offsets,$i }
   else { $s->{index}{$key}=[$offsets,$i] }
}
sub FETCH {
   my ($s,$key)=@_;
   my $i=$s->_lookup($key);
   return unless defined $i;
   $i=$i->[-1] if ref $i;
   return $s->{tokens}[$i+1];
}
# Resolver lookup: presence, selected value, and stable selected-member offset.
sub _get {
   my ($s,$key)=@_;
   my $i=$s->_lookup($key);
   return (0,undef,undef) unless defined $i;
   $i=$i->[-1] if ref $i;
   return (1,$s->{tokens}[$i+1],$i);
}
# Installing a cloned ancestor changes only the selected member's value. A user
# assignment still goes through STORE, which collapses that key's duplicates.
sub _replace_slot {
   my ($s,$slot,$value)=@_;
   $EXEC->_tick(1) if $EXEC;
   $s->{tokens}[$slot+1]=$value;
}
sub EXISTS { defined $_[0]->_lookup($_[1]) }
sub STORE {
   my ($s,$key,$value)=@_;
   my $i=$s->_lookup($key);
   unless (defined $i) {
      $EXEC->_reserve(0,64+4*length($key),0) if $EXEC;
      $s->{index}{$key}=$s->_add($key,$value);
      return $value;
   }
   if (ref $i) {
      my $offsets=$i;
      $i=$offsets->[-1];
      $EXEC->_tick(4*(@$offsets-1)) if $EXEC;
      for my $j (0..$#$offsets-1) { $s->_unlink($offsets->[$j]) }
      $s->{index}{$key}=$i;
   }
   @{$s->{tokens}}[$i,$i+1]=($key,$value);
   return $value;
}
sub DELETE {
   my ($s,$key)=@_;
   my $offsets=$s->_lookup($key);
   return unless defined $offsets;
   my $last=ref($offsets)?$offsets->[-1]:$offsets;
   my $value=$s->{tokens}[$last+1];
   $EXEC->_tick(4*(ref($offsets)?scalar @$offsets:1)) if $EXEC;
   delete $s->{index}{$key};
   if (ref $offsets) { $s->_unlink($_) for @$offsets }
   else { $s->_unlink($offsets) }
   return $value;
}
sub CLEAR { %{$_[0]}=(tokens=>[],index=>{},seq=>[]) }
sub SCALAR { scalar keys %{$_[0]{index}} }
sub FIRSTKEY { $_[0]{iterator}=$_[0]{head}; shift->NEXTKEY }
sub NEXTKEY {
   my $s=shift;
   while (defined(my $i=$s->{iterator})) {
      $s->{iterator}=$s->{seq}[$i+1];
      my $key="$s->{tokens}[$i]";
      my $offsets=$s->_lookup($key);
      next if !defined($offsets) || (ref($offsets) && $i!=$offsets->[-1]);
      return $key;
   }
   return;
}
sub _clone {
   my ($s,$map)=@_;
   my $n=@{$s->{tokens}};
   my $keys=keys %{$s->{index}};
   if ($EXEC) {
      $EXEC->_tick(2*$n+$keys);
      $EXEC->_allocation(128+32*$n+64*$keys);
      $EXEC->_reserve(0,0,4);
   }
   my %out;
   my $copy=tie %out,ref($s);
   $copy->{$_}=$s->{$_} for qw(head tail free);
   $copy->{tokens}=[@{$s->{tokens}}];
   $copy->{seq}=[@{$s->{seq}}];
   {
      my $scratch_base=$EXEC?$EXEC->{scratch_mem}:0;
      local $EXEC->{scratch_mem}=$scratch_base if $EXEC;
      $EXEC->_scratch_set($scratch_base,80+16*$keys) if $EXEC;
      for my $key (keys %{$s->{index}}) {
         my $offsets=$s->{index}{$key};
         if (ref $offsets) {
            if ($EXEC) { $EXEC->_tick(scalar @$offsets); $EXEC->_allocation(80+16*@$offsets) }
            $offsets=[@$offsets];
         }
         $copy->{index}{$key}=$offsets;
      }
   }
   if ($map) {
      for (my $i=$copy->{head};defined $i;$i=$copy->{seq}[$i+1]) {
         $EXEC->_tick(1) if $EXEC;
         $copy->{tokens}[$i+1]=$map->($copy->{tokens}[$i+1]);
      }
   }
   return \%out;
}

=head1 DESCRIPTION

Internal storage for L<JGraft::JSON> objects. FETCH and EXISTS see the final
occurrence. Hash iteration exposes each key once, at its final occurrence's
position. Serialization visits all live occurrences, preserving untouched
members and their original spellings. STORE removes earlier duplicates and
replaces the final member. DELETE removes all occurrences. Reinsertion appends
at the end of the live sequence, reusing a freed slot when available.

A native hash indexes keys by token offset, using an offset array only for
repeated keys. FETCH and EXISTS have expected constant cost plus key hashing.
STORE and DELETE visit each duplicate they remove; ordinary writes are constant
time. Iteration and serialization visit live slots, skipping freed slots through
the sequence links. CLEAR and cloning visit allocated storage. The arrays grow
to accommodate peak member count, rather than the number of writes or distinct
keys ever inserted. Deleted slots release their key and value references.

During execution, lookups, key lengths, duplicate removal, traversal, and
allocations contribute to JGraft's resource counters. No whitespace is retained.

=for Pod::Coverage TIEHASH FETCH EXISTS STORE DELETE CLEAR SCALAR FIRSTKEY NEXTKEY

=cut

1;
