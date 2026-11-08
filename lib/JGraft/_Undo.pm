package JGraft::_Undo;
# VERSION
# ABSTRACT: Lazily construct an undo graft from altered paths
use strict;
use warnings;
no warnings 'recursion';
use Scalar::Util 'refaddr';
use JGraft::Util qw(:types type_mask);

sub _new {
   my ($class,$exec,$input)=@_;
   return bless {target=>$input, paths=>{children=>{}}, original_ids=>{},
      identities=>{}}, $class;
}

# Canonical paths are rooted in the data, independent of AT and namespaces.
# Record before writing: a resource failure during autovivification may leave
# new ancestors even when the final assignment did not happen.
sub _record {
   my ($self,$exec,$loc,$delete,$frames)=@_;
   return unless refaddr($loc->[0])==refaddr($exec->{root});
   my $parts=$loc->[1];
   $exec->_tick(1+@$parts);
   my $node=$self->{paths};
   my $value=$loc->[0][1]? $loc->[0][0] : undef;
   for my $i (0..$#$parts) {
      return if $node->{whole};
      my $key=$parts->[$i];
      my $array=$frames?$frames->[$i][JGraft::Exec::_F_KIND()]==TYPE_ARRAY:ref($value) eq 'ARRAY';
      my $container=$frames?$frames->[$i][JGraft::Exec::_F_CONTAINER()]:$value;
      if ($array && $i==$#$parts
         && ($delete || $key!=int($key) || $key==(defined($container)?scalar @$container:0))) {
         $node->{array}=1;
      }
      $exec->_tick(length($key)*.001) if type_mask($key)==TYPE_STRING;
      my $token=_key($key);
      unless (exists $node->{children}{$token}) {
         $exec->_reserve(0,160+4*length($token),0);
         $node->{children}{$token}=[$key,{children=>{}}];
      }
      $node=$node->{children}{$token}[1];
      $value=(ref($value) eq 'ARRAY' || ref($value) eq 'HASH') && $exec->_present($value,$key)
         ? $exec->_child($value,$key) : undef unless $frames;
   }
   $node->{whole}=1;
   $node->{children}={};
}

sub _build {
   my $self=shift;
   require JGraft;
   my $work=bless {%$self, actions=>[], saves=>[], saved=>{}, next_slot=>0},ref($self);
   $work->_diff($self->{target},$self->{output},[],$self->{paths});
   my $graft=$work->_node('JGraft::Action::JGRAFT',metadata=>{v=>1},actions=>$work->{actions});
   unshift @{$graft->actions},@{$work->{saves}};
   return $graft;
}

sub _key {
   my $value=shift;
   my $type=type_mask($value);
   if ($type==TYPE_DATE) {
      require JGraft::Date;
      my $date=JGraft::Date->new($value);
      return TYPE_DATE.':'.$date->type.':'.$date->to_iso8601;
   }
   return 'r'.refaddr($value) if $type==TYPE_ARRAY || $type==TYPE_OBJECT;
   return $type.':'.(!defined $value? '' : $type==TYPE_BOOLEAN? ($value?1:0) : $value);
}
sub _identity {
   my ($self,$value)=@_;
   my $address=refaddr($value);
   my $identity=$self->{identities}{$address};
   return $identity if $identity && defined($identity->[0]) && refaddr($identity->[0])==$address;
   return;
}
sub _id {
   my ($self,$value)=@_;
   my $identity=$self->_identity($value);
   return $identity?$identity->[1]:'r'.refaddr($value);
}
sub _origin {
   my ($self,$value)=@_;
   my $identity=$self->_identity($value);
   return $identity?$identity->[2]:'r'.refaddr($value);
}
sub _fingerprint {
   my ($self,$value)=@_;
   my $type=type_mask($value);
   return $type==TYPE_ARRAY || $type==TYPE_OBJECT? 'r'.$self->_origin($value) : _key($value);
}
sub _node {
   my ($self,$class,%attrs)=@_;
   return bless {_form=>$class->forms->[0],%attrs},$class;
}
sub _path {
   my ($self,$parts,$namespace)=@_;
   return $self->_node('JGraft::Expr::'.($namespace || 'NODE'),path=>[@$parts]);
}
sub _copy {
   my ($self,$value,$parts)=@_;
   $self->_assign($self->{actions},$value,$self->_path($parts));
}
sub _assign {
   my ($self,$actions,$value,$destination)=@_;
   my $pair=[$value,$destination];
   if (@$actions && $actions->[-1]->name eq 'COPY') {
      push @{$actions->[-1]->assignments},$pair;
   }
   else {
      push @$actions,$self->_node('JGraft::Action::COPY',assignments=>[$pair]);
   }
}

# Capture output references before any reverse edits. Memoized scopes share
# ancestor paths, even when many relocated nodes occur deep in the output.
sub _save_scope {
   my ($self,$link)=@_;
   return $self->{saves} unless $link;
   return $link->[2] if $link->[2];
   my $parent=$self->_save_scope($link->[0]);
   my $actions=[];
   push @$parent,$self->_node('JGraft::Action::AT',path=>$self->_path([$link->[1]]),actions=>$actions);
   return $link->[2]=$actions;
}
sub _move {
   my ($self,$pairs)=@_;
   return unless @$pairs;
   push @{$self->{actions}},$self->_node('JGraft::Action::MOVE',moves=>$pairs);
}

# Index changed/new containers, stopping at borrowed original subtrees. The
# linked paths avoid copying every ancestor path while traversing large arrays.
sub _index {
   my ($self,$value,$link)=@_;
   my $type=type_mask($value);
   return unless $type==TYPE_ARRAY || $type==TYPE_OBJECT;
   my $id=$self->_id($value);
   return if exists $self->{exact}{$id};
   my $entry=[$value,$link];
   $self->{exact}{$id}=$entry;
   $self->{origins}{$self->_origin($value)} ||= $entry;
   return if $self->{original_ids}{$id};
   if ($type==TYPE_ARRAY) {
      for my $i (0..$#$value) { $self->_index($value->[$i],[$link,$i]) }
   }
   else {
      for my $key (keys %$value) { $self->_index($value->{$key},[$link,$key]) }
   }
}
sub _restore {
   my ($self,$wanted,$parts)=@_;
   my $type=type_mask($wanted);
   if ($type==TYPE_ARRAY || $type==TYPE_OBJECT) {
      unless (exists $self->{exact}) {
         $self->{exact}={}; $self->{origins}={};
         $self->_index($self->{output},undef);
      }
      my $entry=$self->{exact}{$self->_id($wanted)} || $self->{origins}{$self->_origin($wanted)};
      if ($entry) {
         my ($available,$link)=@$entry;
         my $id=$self->_id($available);
         unless (exists $self->{saved}{$id}) {
            my $slot=$self->{next_slot}++;
            $self->_assign($self->_save_scope($link),$self->_path([]),$self->_path([$slot],'STASH'));
            $self->{saved}{$id}=$slot;
         }
         $self->_copy($self->_path([$self->{saved}{$id}],'STASH'),$parts);
         $self->_diff($wanted,$available,$parts,undef);
         return;
      }
   }
   # Input subtrees are immutable. Bypass public constructors' literal cloning;
   # only values actually absent from output need embedding in the undo graft.
   $self->_copy($wanted,$parts);
}
sub _diff {
   my ($self,$wanted,$have,$parts,$hint)=@_;
   return if $hint && !$hint->{whole} && !keys %{$hint->{children}};
   my ($wt,$ht)=(type_mask($wanted),type_mask($have));
   if ($wt==$ht) {
      if ($wt==TYPE_ARRAY || $wt==TYPE_OBJECT) { return if refaddr($wanted)==refaddr($have) }
      elsif ($wt==TYPE_NULL) { return }
      elsif ($wt==TYPE_STRING) {
         return if $wanted eq $have;
      }
      elsif ($wt==TYPE_DATE) { return if _key($wanted) eq _key($have) }
      elsif ($wt==TYPE_NUMBER && (ref($wanted) || ref($have))) {
         return if ref($wanted) && ref($have) && refaddr($wanted)==refaddr($have);
         # Avoid expanding huge exponent tokens just to optimize an undo. A
         # literal replacement is always correct when comparison is expensive.
         if (JGraft::Util::estimate_number_digits($wanted)<=10000 && JGraft::Util::estimate_number_digits($have)<=10000) {
            my $same=eval { !JGraft::Util::to_rational($wanted)->bcmp(JGraft::Util::to_rational($have)) };
            return if $same;
         }
      }
      else { return if $wanted==$have }
   }
   unless ($wt==$ht && ($wt==TYPE_ARRAY || $wt==TYPE_OBJECT) && $self->_origin($wanted) eq $self->_origin($have)) {
      $self->_restore($wanted,$parts);
      return;
   }
   if (@$parts) {
      my $parent=$self->{actions};
      local $self->{actions}=[];
      $self->_contents($wanted,$have,$hint);
      push @$parent,$self->_node('JGraft::Action::AT',path=>$self->_path($parts),actions=>$self->{actions})
         if @{$self->{actions}};
   }
   else { $self->_contents($wanted,$have,$hint) }
}

# Within a container, every child selector is relative to its AT scope.
sub _contents {
   my ($self,$wanted,$have,$hint)=@_;
   my $wt=type_mask($wanted);
   if ($wt==TYPE_ARRAY) {
      if ($hint && !$hint->{whole} && !$hint->{array} && @$wanted==@$have) {
         for my $entry (values %{$hint->{children}}) {
            my ($i,$child)=@$entry;
            $self->_diff($wanted->[$i],$have->[$i],[$i],$child);
         }
      }
      else { $self->_array($wanted,$have) }
      return;
   }
   my %keys;
   if ($hint && !$hint->{whole}) {
      %keys=map { $_->[0]=>$_->[1] } values %{$hint->{children}};
   }
   else {
      %keys=map {$_=>undef} (keys %$wanted,keys %$have);
   }
   my @remove;
   for my $key (sort keys %keys) {
      my $path=[$key];
      if (!exists $wanted->{$key}) {
         push @remove,[$self->_path($path),undef] if exists $have->{$key};
      }
      elsif (!exists $have->{$key}) { $self->_restore($wanted->{$key},$path) }
      else { $self->_diff($wanted->{$key},$have->{$key},$path,$keys{$key}) }
   }
   $self->_move(\@remove);
}

# Match equal scalars and container ancestry, then retain an increasing sequence
# of matches. This keeps a single array insertion/deletion/rotation small without
# a quadratic LCS table. Repeated equal values are paired in occurrence order.
sub _array {
   my ($self,$wanted,$have)=@_;
   my (%positions,%cursor);
   for my $i (0..$#$have) { push @{$positions{$self->_fingerprint($have->[$i])}},$i }
   my (@tails,@ends,@previous,@match);
   for my $i (0..$#$wanted) {
      my $key=$self->_fingerprint($wanted->[$i]);
      my $list=$positions{$key} || next;
      my $cursor=$cursor{$key} || 0;
      next if $cursor>=@$list;
      $cursor{$key}=$cursor+1;
      my $pos=$list->[$cursor];
      $match[$i]=$pos;
      my ($low,$high)=(0,scalar @tails);
      while ($low<$high) {
         my $mid=int(($low+$high)/2);
         if ($tails[$mid]<$pos) { $low=$mid+1 } else { $high=$mid }
      }
      $previous[$i]=$low? $ends[$low-1] : undef;
      $tails[$low]=$pos;
      $ends[$low]=$i;
   }
   my @anchors;
   my $i=@ends? $ends[-1] : undef;
   while (defined $i) {
      push @anchors,[$i,$match[$i]];
      $i=$previous[$i];
   }
   @anchors=(reverse(@anchors),[scalar @$wanted,scalar @$have]);
   my (@moves,@insert);
   my ($old,$new)=(-1,-1);
   for my $anchor (@anchors) {
      my ($oi,$ni)=@$anchor;
      my $paired=($oi-$old-1)<($ni-$new-1)? $oi-$old-1 : $ni-$new-1;
      for my $offset (1..$paired) {
         $self->_diff($wanted->[$old+$offset],$have->[$new+$offset],[$new+$offset],undef);
      }
      for my $pos ($new+$paired+1..$ni-1) { push @moves,[$self->_path([$pos]),undef] }
      for my $pos ($old+$paired+1..$oi-1) {
         push @moves,[undef,$self->_path([$ni-.5])];
         push @insert,$pos;
      }
      if ($oi<@$wanted) { $self->_diff($wanted->[$oi],$have->[$ni],[$ni],undef) }
      ($old,$new)=($oi,$ni);
   }
   $self->_move(\@moves);
   $self->_restore($wanted->[$_],[$_]) for @insert;
}

1;
