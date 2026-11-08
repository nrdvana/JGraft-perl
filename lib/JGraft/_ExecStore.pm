package JGraft::Exec;
# VERSION
# ABSTRACT: Private execution allocation, resolution, and mutation methods
use strict;
use warnings;
no warnings 'recursion';
use Scalar::Util qw(blessed refaddr weaken);
use JSON::PP ();
use JGraft::Util qw(:types type_mask is_finite is_integer is_expr is_action);

# Hot budget checks keep failed reservations observable: ops, objects, then mem.
# Compact path frames avoid a hash allocation per ancestor. These offsets
# describe scratch records only; persistent container metadata stays named.
use constant _F_CONTAINER => 0;
use constant _F_KIND => 1;
use constant _F_KEY => 2;
use constant _F_EXISTS => 3;
use constant _F_VALUE => 4;
use constant _F_RECORD => 5;
use constant _F_SLOT => 6;

sub _tick {
   my ($self,$ops)=@_;
   $ops=JGraft::Util::to_native_number($ops) if ref $ops;
   $self->{count}{ops}+=$ops;
   my $limit=$self->{limits}{ops};
   !defined($limit) || $self->{count}{ops}<=$limit
      or $self->_fail('RESOURCE_LIMIT','ops limit exceeded');
}
sub _depth {
   my ($self,$depth)=@_;
   return if $depth<=$self->{count}{depth};
   $self->{count}{depth}=$depth;
   my $limit=$self->{limits}{depth};
   !defined($limit) || $depth<=$limit
      or $self->_fail('RESOURCE_LIMIT','depth limit exceeded');
}
sub _enter {
   my ($self,$depth)=@_;
   if ($depth>$self->{count}{depth}) {
      $self->{count}{depth}=$depth;
      my $limit=$self->{limits}{depth};
      !defined($limit) || $depth<=$limit
         or $self->_fail('RESOURCE_LIMIT','depth limit exceeded');
   }
   ++$self->{count}{ops};
   my $limit=$self->{limits}{ops};
   !defined($limit) || $self->{count}{ops}<=$limit
      or $self->_fail('RESOURCE_LIMIT','ops limit exceeded');
}
sub _reserve {
   my ($self,$ops,$bytes,$objects)=@_;
   if ($ops) {
      $ops=JGraft::Util::to_native_number($ops) if ref $ops;
      $self->{count}{ops}+=$ops;
      my $limit=$self->{limits}{ops};
      !defined($limit) || $self->{count}{ops}<=$limit
         or $self->_fail('RESOURCE_LIMIT','ops limit exceeded');
   }
   if ($objects) {
      $self->{count}{new_obj}+=$objects;
      my $limit=$self->{limits}{new_obj};
      !defined($limit) || $self->{count}{new_obj}<=$limit
         or $self->_fail('RESOURCE_LIMIT','new_obj limit exceeded');
   }
   if ($bytes) {
      $bytes=JGraft::Util::to_native_number($bytes) if ref $bytes;
      $self->{count}{mem}+=$bytes;
      my $limit=$self->{limits}{mem};
      !defined($limit) || $self->{count}{mem}+$self->{scratch_mem}<=$limit
         or $self->_fail('RESOURCE_LIMIT',$self->{scratch_mem}
            ? 'mem limit exceeded with active scratch' : 'mem limit exceeded');
   }
}
sub _scratch_set {
   my ($self,$base,$bytes)=@_;
   $self->{scratch_mem}=$base+$bytes;
   my $limit=$self->{limits}{mem};
   !defined($limit) || $self->{count}{mem}+$self->{scratch_mem}<=$limit
      or $self->_fail('RESOURCE_LIMIT','mem limit exceeded by scratch workspace');
}
sub _allocation { $_[0]->_reserve(0,$_[1]+64,1) }
# Register only after the allocation primitive has paid for this record and its
# optional undo identity. Undo keeps a separate weak identity, without metadata.
sub _register_container {
   my ($self,$value,$epoch,$capacity)=@_;
   my $address=refaddr($value);
   my $id=++$self->{next_container_id};
   my $record={ref=>$value,id=>$id,kind=>ref($value) eq 'ARRAY'?'ARRAY':'OBJECT',
      owner_epoch=>$epoch,reserved_slots=>$capacity};
   weaken($record->{ref});
   if (my $undo=$self->{undo_state}) {
      $record->{origin_id}=$id;
      my $identity=[$value,$id,$id];
      weaken($identity->[0]);
      $undo->{identities}{$address}=$identity;
   }
   $self->{containers}{$address}=$record;
   return $record;
}
# Reads do not create records. An expired or mismatched weak owner invalidates
# every optional field together, including capacity, dates, split, and pending.
sub _container {
   my ($self,$value,$create)=@_;
   return unless ref $value;
   my $address=refaddr($value);
   my $record=$self->{containers}{$address};
   return $record if $record && defined($record->{ref}) && refaddr($record->{ref})==$address;
   return unless $create;
   $self->_reserve(0,224+($self->{undo_state}?128:0),0);
   # Borrowed slots are pre-existing data, not paid construction capacity. In
   # particular, registering an exact object must not enumerate its tied keys.
   return $self->_register_container($value,0,undef);
}
sub _inherit_origin {
   my ($self,$source,$copy)=@_;
   return unless $self->{undo_state};
   my $origin=$self->_container($source,1)->{origin_id};
   $self->_container($copy)->{origin_id}=$origin;
   $self->{undo_state}{identities}{refaddr($copy)}[2]=$origin;
}
# Compatibility access until resolution traces carry the record directly.
sub _split_meta {
   my ($self,$value)=@_;
   return unless @_>2 || $self->{has_split};
   my $record=$self->_container($value,@_>2 && defined($_[2]));
   return unless $record;
   if (@_>2) {
      if (defined $_[2]) { $record->{split}=$_[2]; $self->{has_split}=1 }
      else { delete $record->{split} }
   }
   return $record->{split};
}
sub _own {
   my ($s,$v)=@_;
   $s->_reserve(0,224+($s->{undo_state}?128:0),0);
   $s->_register_container($v,$s->{epoch},0);
   $v;
}
sub _alloc_hash {
   my ($s,$n)=@_;
   $s->_reserve(0,416+64*$n+($s->{undo_state}?128:0),1);
   my $v={};
   $s->_register_container($v,$s->{epoch},$n);
   return $v;
}
# Keep empty allocation's hot path small. A plain-table copy reserves its full
# temporary key/value list and combines retained allocation with copy work.
sub _copy_hash {
   my ($s,$source,$capacity)=@_;
   my $keys=scalar keys %$source;
   $capacity=$keys unless defined $capacity;
   my $scratch_base=$s->{scratch_mem};
   local $s->{scratch_mem}=$scratch_base;
   $s->_scratch_set($scratch_base,80+32*$keys);
   $s->_reserve($keys,416+64*$capacity+($s->{undo_state}?128:0),1);
   my $v={%$source};
   $s->_register_container($v,$s->{epoch},$capacity);
   return $v;
}
sub _alloc_array {
   my ($s,$n)=@_;
   $s->_reserve(0,368+16*$n+($s->{undo_state}?128:0),1);
   my $v=[];
   $s->_register_container($v,$s->{epoch},$n);
   return $v;
}

# Paid capacity survives deletion/shrinking; filling it never buys the same slot
# twice. Unregistered arrays conservatively start at their populated size.
sub _grow_array {
   my ($self,$array,$size)=@_;
   my $record=$self->_container($array);
   my $capacity=$record && defined($record->{reserved_slots})? $record->{reserved_slots} : scalar @$array;
   return if $size<=$capacity;
   $self->_reserve(0,16*($size-$capacity),0);
   $record->{reserved_slots}=$size if $record;
}

sub _inspect_tree {
   my ($self,$value,$ast,$alloc)=@_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{inspect_workspace}=[$scratch_base,128];
   $self->_scratch_set($scratch_base,128);
   $self->_inspect($value,1,{},$ast,$alloc);
}
sub _inspect {
   my ($self,$v,$depth,$active,$ast,$alloc)= @_;
   $self->_enter($depth);
   if ($ast && (is_action($v) || is_expr($v))) {
      my $id= refaddr($v);
      $active->{$id} and $self->_fail('INVALID_GRAFT','Cyclic graft');
      my $workspace=$self->{inspect_workspace};
      local $workspace->[1]=$workspace->[1]+144+32*keys %$v;
      local $self->{scratch_mem}=$self->{scratch_mem};
      $self->_scratch_set(@$workspace);
      local $active->{$id}=1;
      my $fields=$v->can('_operand_fields')?$v->_operand_fields:undef;
      my @keys=$fields?grep(exists($v->{$_}),@$fields):grep($_ ne '_form',keys %$v);
      $self->_tick(scalar @keys);
      $self->_inspect($v->{$_},$depth+1,$active,1,$alloc) for @keys;
      return;
   }
   my $type= type_mask($v);
   if ($type==TYPE_DATE) { $self->_date($v); return }
   if (!ref $v || JSON::PP::is_bool($v) || $type==TYPE_NUMBER || $type==TYPE_STRING) {
      $self->_tick(length($v)*.001) if $type == TYPE_STRING;
      $self->_check_string($v,$ast?'graft':'input') if $type == TYPE_STRING;
      $type != TYPE_NUMBER || is_finite($v) or $self->_fail('UNSUPPORTED_GRAFT','Non-finite input number');
      if ($type==TYPE_NUMBER && ref $v) {
         $self->_tick((JGraft::Util::_number_sizes($v))[0]);
      }
      return;
   }
   ref($v) eq 'ARRAY' || ref($v) eq 'HASH' or $self->_fail('UNSUPPORTED_GRAFT','Unsupported data reference '.ref($v));
   my $id=refaddr($v);
   $active->{$id} and $self->_fail($ast?'INVALID_GRAFT':'INVALID_TARGET','Cyclic data');
   my $workspace=$self->{inspect_workspace};
   local $workspace->[1]=$workspace->[1]+64;
   local $self->{scratch_mem}=$self->{scratch_mem};
   $self->_scratch_set(@$workspace);
   local $active->{$id}=1;
   my $n= $type==TYPE_ARRAY? scalar @$v : scalar keys %$v;
   if (!$ast && $self->{undo_state}) {
      my $serial=$self->_container($v,1)->{id};
      unless ($self->{undo_state}{original_ids}{$serial}) {
         $self->_reserve(0,32,0);
         $self->{undo_state}{original_ids}{$serial}=1;
      }
   }
   $self->_tick($n);
   $self->_allocation(($type==TYPE_ARRAY?80:128)+($type==TYPE_ARRAY?16:64)*$n) if $alloc;
   if ($type==TYPE_ARRAY) {
      for (my $i=0;$i<$n;++$i) {
         exists $v->[$i] or $self->_fail('UNSUPPORTED_GRAFT','Sparse input arrays are not JSON data');
         $self->_inspect($v->[$i],$depth+1,$active,$ast,$alloc);
         $self->_mark_date_container($v) if $self->_contains_date($v->[$i]);
      }
   }
   else {
      my $tie=tied %$v;
      if ($tie && $tie->isa('JGraft::JSON::Object')) {
         # Follow live members directly, avoiding a temporary offset list while
         # retaining hidden-duplicate inspection and its traversal work.
         for (my $i=$tie->{head};defined $i;$i=$tie->{seq}[$i+1]) {
            $self->_tick(1);
            $self->_check_string($tie->{tokens}[$i],$ast?'graft key':'input key');
            $self->_inspect($tie->{tokens}[$i+1],$depth+1,$active,$ast,$alloc);
            $self->_mark_date_container($v) if $self->_contains_date($tie->{tokens}[$i+1]);
         }
         return;
      }
      $workspace->[1]+=80+16*$n;
      $self->_scratch_set(@$workspace);
      for my $key (keys %$v) {
         $self->_tick(length($key)*.001);
         $self->_check_string($key,$ast?'graft key':'input key');
         $self->_inspect($v->{$key},$depth+1,$active,$ast,$alloc);
         $self->_mark_date_container($v) if $self->_contains_date($v->{$key});
      }
   }
}

sub _check_string {
   my ($self,$value,$kind)=@_;
   require JGraft::_String;
   JGraft::_String->_check($self,$value,$kind);
}

sub _cow {
   my ($self,$v,$record,$known)= @_;
   $record=$self->_container($v) unless $known;
   return $v if $record && $record->{owner_epoch}==$self->{epoch};
   if (ref $v eq 'ARRAY') {
      my $copy=$self->_alloc_array(scalar @$v);
      $self->_tick(scalar @$v);
      @$copy=@$v;
      $self->_mark_date_container($copy) if $record && $record->{may_have_dates};
      JGraft::_Split->_copy_meta($self,$v,$copy,0,scalar @$v) if $record && $record->{split};
      $self->_inherit_origin($v,$copy) if $self->{undo_state};
      return $copy;
   }
   my $tie=tied %$v;
   my $copy;
   if ($tie && $tie->isa('JGraft::JSON::Object')) { $copy=$self->_own($tie->_clone) }
   else {
      $copy=$self->_copy_hash($v);
   }
   $self->_mark_date_container($copy) if $record && $record->{may_have_dates};
   $self->_inherit_origin($v,$copy) if $self->{undo_state};
   return $copy;
}
sub _publish {
   my ($self,$v,$export,$depth)= @_;
   $v=$self->_export_dates($v,$depth) if $export;
   # Existing owned descendants can occur anywhere in a logical copy. Freezing
   # the generation avoids traversing that subtree to invalidate ownership.
   ++$self->{epoch} if ref($v) eq 'ARRAY' || ref($v) eq 'HASH';
   return $v;
}
sub _clone_tree {
   my ($self,$v,$depth)= @_;
   $self->_enter($depth);
   if (blessed($v) && $v->isa('DateTime')) { $self->_allocation(256); return $v->clone }
   if (blessed($v) && type_mask($v)==TYPE_NUMBER && !$v->isa('JGraft::JSON::Number')) {
      my $size=(JGraft::Util::_number_sizes($v))[0];
      $self->_tick($size);
      $self->_allocation(128+4*$size);
      return $v->copy;
   }
   return $v unless ref $v eq 'ARRAY' || ref $v eq 'HASH';
   if (ref $v eq 'ARRAY') {
      my $out=$self->_alloc_array(scalar @$v);
      $self->_inherit_origin($v,$out) if $self->{undo_state};
      $self->_tick(scalar @$v);
      for my $i (0..$#$v) { $out->[$i]=$self->_clone_tree($v->[$i],$depth+1) }
      $self->_mark_date_container($out) if $self->_contains_date($v);
      JGraft::_Split->_copy_meta($self,$v,$out,0,scalar @$v) if $self->_split_meta($v);
      return $out;
   }
   my $tie=tied %$v;
   my $out;
   if ($tie && $tie->isa('JGraft::JSON::Object')) {
      $out=$self->_own($tie->_clone(sub { $self->_clone_tree($_[0],$depth+1) }));
   }
   else {
      my $scratch_base=$self->{scratch_mem};
      local $self->{scratch_mem}=$scratch_base;
      $self->_scratch_set($scratch_base,80+16*keys %$v);
      $out=$self->_alloc_hash(scalar keys %$v);
      $self->_tick(scalar keys %$v);
      $self->_set_member($out,$_,$self->_clone_tree($v->{$_},$depth+1)) for keys %$v;
   }
   $self->_inherit_origin($v,$out) if $self->{undo_state};
   $self->_mark_date_container($out) if $self->_contains_date($v);
   return $out;
}

# The consuming operation owns vectors/traces through their last use. MOVE also
# holds its queues until finalization, resetting only pair-local path workspace.
sub _path_scratch {
   my ($self,$bytes)=@_;
   my $owner=$self->{path_workspace};
   my $total=$owner->[1]+=$bytes;
   $self->_scratch_set($owner->[0],$total);
}
sub _expand_path {
   my ($self,$expr,$mode,$depth)= @_;
   $self->_enter($depth);
   is_expr($expr) or $self->_fail('INVALID_OPERAND','Path must be a reference expression');
   local $self->{expression}=$expr;
   if ($expr->name eq 'EXPR') {
      return $self->_expand_path($self->_macro($expr,$depth+1),$mode,$depth+1);
   }
   $expr->is_ref && exists $expr->{path} or $self->_fail('INVALID_OPERAND','Path must be a reference');
   my $ns=lc($expr->name);
   if ($mode eq 'at') { $ns eq 'node' or $self->_fail('INVALID_OPERAND','AT must use NODE') }
   if ($mode eq 'write' || $mode eq 'move_src' || $mode eq 'move_dst') {
      $ns =~ /\A(?:node|temp|stash)\z/ or $self->_fail('INVALID_OPERAND','Read-only namespace');
   }
   my $base=$ns eq 'node'? $self->{current} : [$self->{$ns},[]];
   defined $base->[0] or $self->_fail('INVALID_OPERAND','Unknown namespace');
   $self->_path_scratch(64+32*@{$expr->{path}});
   my (@parts,@literal);
   $self->_tick(scalar @{$expr->{path}});
   for my $part (@{$expr->{path}}) {
      my $value=$self->_eval($part,$depth+1);
      if (ref $value eq 'ARRAY') {
         $self->_tick(scalar @$value);
         $self->_path_scratch(32*(@$value-1)) if @$value>1;
         for my $i (0..$#$value) {
            $self->_present($value,$i) or $self->_fail('INVALID_TARGET','Path expands a deleted element');
            push @parts,$value->[$i];
            push @literal,!is_expr($part) && !is_expr($part->[$i]);
         }
      }
      else { push @parts,$value; push @literal,!is_expr($part) }
   }
   $self->_tick(scalar @parts);
   for my $i (0..$#parts) {
      my $v=$parts[$i];
      my $t=type_mask($v);
      next if $t==TYPE_STRING || ($t==TYPE_BOOLEAN && !$v);
      if ($t==TYPE_NUMBER && is_finite($v)) {
         next if is_integer($v) || ($mode eq 'move_dst' && $i==$#parts && $v*2==int($v*2));
      }
      $self->_fail($literal[$i]?'INVALID_GRAFT':'INVALID_OPERAND','Invalid path selector');
   }
   $ns eq 'temp' && !@parts and $self->_fail(
      (grep is_expr($_), @{$expr->{path}})?'INVALID_OPERAND':'INVALID_GRAFT','TEMP root is inaccessible');
   if ($ns ne 'node' && ($mode eq 'write' || $mode =~ /^move_/) && !@parts) {
      $self->_fail((grep is_expr($_), @{$expr->{path}})?'INVALID_OPERAND':'INVALID_GRAFT','Namespace root cannot be overwritten or moved');
   }
   if ($ns ne 'node' && @parts && type_mask($parts[0])==TYPE_NUMBER) {
      is_integer($parts[0]) or $self->_fail($literal[0]?'INVALID_GRAFT':'INVALID_OPERAND',
         'Namespace property must be an integer or string');
      my $key=$parts[0];
      $parts[0]="$key";
   }
   $self->_path_scratch(32+16*(@parts+@{$base->[1]}));
   return [$base->[0],[@{$base->[1]},@parts],$ns];
}

sub _selector {
   my ($self,$value,$container,$half,$kind,$len,$mode)= @_;
   # Reserved for a future scoped matcher policy, before alias normalization.
   # No public fuzzy option activates this; bulk access needs its own policy too.
   if (my $remap=$self->{path_remap}) {
      my $record=(ref($container) eq 'ARRAY' || ref($container) eq 'HASH')?$self->_container($container,1):undef;
      $value=$remap->($self,$record,$value,$mode || 'read');
   }
   my $type=type_mask($value);
   $kind=type_mask($container) unless defined $kind;
   if ($kind==TYPE_DATE) {
      $type==TYPE_STRING or $self->_fail('INVALID_TARGET','Date selectors must be field names');
      return $value;
   }
   if ($kind==TYPE_OBJECT) {
      $type==TYPE_STRING or $self->_fail('INVALID_TARGET','Object selectors must be strings');
      return $value;
   }
   $kind==TYPE_ARRAY or $self->_fail('INVALID_TARGET','Path descends through a scalar');
   $len=@$container unless defined $len;
   return $len if $type==TYPE_BOOLEAN && !$value;
   $type==TYPE_NUMBER && is_finite($value) or $self->_fail('INVALID_TARGET','Array selectors must be numbers');
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   $value=$self->_number($value,[$scratch_base,0]) if ref $value;
   if (is_integer($value)) {
      my $index=$value<0? $len+$value : 0+$value;
      $index>=0 && $index<=$len or $self->_fail('INVALID_TARGET','Array index out of range');
      return ref($index)?JGraft::Util::to_native_number($index):$index;
   }
   $half && $value*2==int($value*2) or $self->_fail('INVALID_OPERAND','Invalid fractional selector');
   my $index=$value<-.5? $len+$value : 0+$value;
   $index>=-.5 && $index<=$len-.5 or $self->_fail('INVALID_TARGET','Array insertion out of range');
   return ref($index)?JGraft::Util::to_native_number($index):$index;
}
sub _present {
   my ($self,$v,$key)= @_;
   return $self->_date($v)->_has($key) if type_mask($v)==TYPE_DATE;
   return exists $v->{$key} if ref $v eq 'HASH';
   return 0 unless is_integer($key) && $key>=0 && $key<@$v && exists $v->[$key];
   my $record=$self->{moving} && $self->_container($v);
   my $pending=$record && $record->{pending};
   return !$pending || !$pending->{deleted}{0+$key};
}
sub _child {
   if (type_mask($_[1])==TYPE_DATE) {
      my $date=$_[0]->_date($_[1]);
      if ($_[2] eq 'second') {
         my $n=length($date->fraction);
         $_[0]->_tick($n*.01+1); $_[0]->_reserve(0,2*$n,0);
      }
      my $value=eval { $date->_get($_[2]) };
      my $error=$@;
      if ($error) {
         die $error if ref($error) || $error !~ /\AUNSUPPORTED_GRAFT:/;
         $_[0]->_fail('UNSUPPORTED_GRAFT',"$error");
      }
      return $value;
   }
   return ref($_[1]) eq 'ARRAY'? $_[1][$_[2]] : $_[1]{$_[2]};
}
sub _same_key {
   my ($self,$a,$b)= @_;
   return 0 unless type_mask($a)==type_mask($b);
   $self->_tick(1+(length($a)+length($b))*.001) if type_mask($a)==TYPE_STRING;
   return $a eq $b;
}
# One lookup for known representations; ordinary hashes preserve null/presence.
sub _lookup_child {
   my ($self,$value,$key,$kind,$record)=@_;
   if ($kind==TYPE_OBJECT) {
      my $tie=tied %$value;
      return $tie->_get($key) if $tie && $tie->isa('JGraft::JSON::Object');
      return exists($value->{$key})?(1,$value->{$key}):(0,undef);
   }
   if ($kind==TYPE_ARRAY) {
      return (0,undef) unless $key==int($key) && $key>=0 && $key<@$value && exists $value->[$key];
      $record=$self->_container($value) if !$record && $self->{moving};
      return (0,undef) if $record && $record->{pending} && $record->{pending}{deleted}{0+$key};
      return (1,$value->[$key]);
   }
   my $present=$self->_present($value,$key);
   return ($present,$present?$self->_child($value,$key):undef);
}
sub _resolve {
   my ($self,$loc,$mode,$removed,$want_source)=@_;
   my ($cell,$parts)=@$loc;
   my $read=$mode eq 'read';
   $self->_tick(1+@$parts);
   $self->_depth(1+@$parts);
   $self->_path_scratch(192+208*@$parts);
   my $match=$removed && refaddr($removed->[0])==refaddr($cell);
   my $exists=$cell->[1] && !($match && !@{$removed->[1]});
   $exists || !$read or $self->_fail('INVALID_TARGET','Current node does not exist');
   my $value=$cell->[0];
   my (@canonical,@frames);
   for my $i (0..$#$parts) {
      my $kind=$exists?type_mask($value):type_mask($parts->[$i])==TYPE_STRING?TYPE_OBJECT:TYPE_ARRAY;
      !$read && $kind==TYPE_DATE and $self->_fail('INVALID_TARGET','Date fields are immutable');
      my $key=$self->_selector($parts->[$i],$value,$mode eq 'move_dst' && $i==$#$parts,$kind,
         $kind==TYPE_ARRAY?($exists?scalar @$value:0):0,$mode);
      my $record=$exists && ($kind==TYPE_ARRAY || $kind==TYPE_OBJECT)?$self->_container($value):undef;
      my ($present,$child,$slot)=$exists?$self->_lookup_child($value,$key,$kind,$record):(0,undef);
      if ($match) {
         $match=$i<@{$removed->[1]} && $self->_same_key($key,$removed->[1][$i]);
         $present=0 if $match && $i==$#{$removed->[1]};
      }
      $present || !$read or $self->_fail('INVALID_TARGET','Path does not exist');
      push @frames,[$exists?$value:undef,$kind,$key,$present,$present?$child:undef,$record,$slot];
      push @canonical,$key;
      ($value,$exists)=($present?$child:undef,$present);
   }
   my $trace={location=>[$cell,\@canonical,$loc->[2]],frames=>\@frames,
      value=>$value,exists=>$exists,revision=>$self->{revision},root_exists=>$cell->[1],mode=>$mode};
   if ($want_source && @frames) {
      my $frame=$frames[-1];
      my $meta=$frame->[_F_RECORD] && $frame->[_F_RECORD]{split};
      $trace->{source}={origin=>$meta->{origin},separators=>$meta->{separators},
         trims=>$meta->{trims},row=>$meta->{rows}[$frame->[_F_KEY]]} if $meta && $frame->[_F_EXISTS];
   }
   return $trace;
}
# The unboxed read path does not build frames when only a value is wanted.
sub _read_value {
   my ($self,$loc,$source)=@_;
   if ($source && $self->{has_split}) {
      my $trace=$self->_resolve($loc,'read',undef,1);
      $$source=$trace->{source};
      return $trace->{value};
   }
   $$source=undef if $source;
   my ($cell,$parts)=@$loc;
   $self->_tick(1+@$parts);
   $self->_depth(1+@$parts);
   $cell->[1] or $self->_fail('INVALID_TARGET','Current node does not exist');
   my $value=$cell->[0];
   for my $part (@$parts) {
      my $kind=type_mask($value);
      my $key=$self->_selector($part,$value,0,$kind);
      my ($exists,$child)=$self->_lookup_child($value,$key,$kind);
      $exists or $self->_fail('INVALID_TARGET','Path does not exist');
      $value=$child;
   }
   return $value;
}
# Rebind saved canonical keys after a prior mutation (not selector expressions).
sub _prepare_write {
   my ($self,$trace,$edit)=@_;
   $trace=$self->_resolve($trace->{location},$edit eq 'remove'?'read':$trace->{mode} eq 'move_dst'?'move_dst':'write')
      if $trace->{revision}!=$self->{revision};
   my $loc=$trace->{location};
   $self->{undo_state}->_record($self,$loc,$edit eq 'remove',$trace->{frames})
      if $self->{undo_state} && $edit ne 'splice';
   my ($cell,$parts)=@$loc;
   return $trace unless @$parts;
   my $previous;
   for my $frame (@{$trace->{frames}}) {
      $frame->[_F_KIND]!=TYPE_DATE or $self->_fail('INVALID_TARGET','Date fields are immutable');
      my $old=$frame->[_F_CONTAINER];
      my $record=$frame->[_F_RECORD];
      my $changed=!$record || $record->{owner_epoch}!=$self->{epoch};
      my $value=$changed?(defined($old)?$self->_cow($old,$record,1)
         :$frame->[_F_KIND]==TYPE_OBJECT?$self->_alloc_hash(0):$self->_alloc_array(0)):$old;
      if ($previous) {
         if ($changed || !$previous->[_F_EXISTS]) {
            $self->_link_child($previous,$value);
         }
         $previous->[_F_EXISTS]=1;
         $previous->[_F_VALUE]=$value;
      }
      elsif ($changed || !$cell->[1]) {
         @$cell=($value,1);
         ++$self->{revision};
      }
      $frame->[_F_CONTAINER]=$value;
      $frame->[_F_RECORD]=$self->_container($value) if $changed;
      $previous=$frame;
   }
   $trace->{revision}=$self->{revision};
   return $trace;
}
sub _link_child {
   my ($self,$frame,$value)=@_;
   my $parent=$frame->[_F_CONTAINER];
   if ($frame->[_F_EXISTS]) {
      if ($frame->[_F_KIND]==TYPE_ARRAY) { $parent->[$frame->[_F_KEY]]=$value }
      else {
         my $tie=tied %$parent;
         if ($tie && $tie->isa('JGraft::JSON::Object')) { $tie->_replace_slot($frame->[_F_SLOT],$value) }
         else { $parent->{$frame->[_F_KEY]}=$value }
      }
   }
   else { $self->_set_member($parent,$frame->[_F_KEY],$value) }
   ++$self->{revision};
}

sub _set_member {
   my ($self,$parent,$key,$value,$source)= @_;
   if (ref $parent eq 'HASH') {
      # Exact JSON owns its backing slots and keys, including duplicate members.
      my $tie=tied %$parent;
      unless ($tie && $tie->isa('JGraft::JSON::Object')) {
         unless (exists $parent->{$key}) {
            my $record=$self->_container($parent);
            my $size=scalar keys %$parent;
            my $capacity=$record && defined($record->{reserved_slots})? $record->{reserved_slots} : $size;
            $self->_reserve(0,length($key)+($size>=$capacity?64:0),0);
            $record->{reserved_slots}=$size+1 if $record && $size>=$capacity;
         }
      }
      $parent->{$key}=$value;
   }
   else {
      my $record=$self->_container($parent);
      my $rec=$record && $record->{pending};
      my $inserting=$key==@$parent || ($rec && $rec->{deleted}{0+$key});
      my $existing_meta=$record && $record->{split};
      my $metadata=$inserting && ($source || $existing_meta);
      $rec=$self->_pending($parent) if $metadata && $self->{moving};
      if ($key==@$parent) {
         $self->_grow_array($parent,scalar(@$parent)+1+($rec? $rec->{insert_count} || 0 : 0));
         if ($rec) {
            $self->_tick($rec->{metadata} || $metadata?4:2);
            $self->_move_scratch(16);
            $self->_reserve(0,96,0) if $rec->{metadata} || $metadata;
         }
      }
      if ($metadata) {
         $self->_reserve(0,96,0);
         $self->_tick($existing_meta?2:2*(@$parent+1)) unless $self->{moving};
         my $row=JGraft::_Split->_insert_meta($self,$parent,$source);
         if (!$row && !$self->{moving} && $existing_meta) {
            my $previous=$key? $existing_meta->{rows}[$key-1] : undef;
            $row=[$previous? $previous->[0] : '',$previous? $previous->[1] : '',''];
         }
         $self->_split_meta($parent)->{rows}[$key]=$row;
      }
      delete $rec->{deleted}{0+$key} if $rec;
      $parent->[$key]=$value;
      JGraft::_Split->_fill_meta($self,$parent,1) if $metadata && !$self->{moving} && !$existing_meta;
   }
   $self->_mark_date_container($parent) if $self->_contains_date($value);
}
# Unpublished construction has no path/undo/revision machinery. Values and
# installed rows are retained; native slice workspace is scoped to this copy.
sub _append_value {
   my ($self,$array,$value,$source)=@_;
   $self->_set_member($array,scalar @$array,$value,$source);
}
sub _append_range {
   my ($self,$out,$source,$start,$count)=@_;
   return unless $count;
   my $base=$self->{scratch_mem};
   local $self->{scratch_mem}=$base;
   $self->_scratch_set($base,80+32*$count);
   $self->_tick($count);
   my $offset=scalar @$out;
   $self->_grow_array($out,$offset+$count);
   my $record=$self->_container($source);
   if ($record && $record->{pending} && keys %{$record->{pending}{deleted}}) {
      for my $i ($start..$start+$count-1) {
         $self->_present($source,$i) or $self->_fail('INVALID_TARGET','Array copy encounters a deleted element');
         push @$out,$source->[$i];
      }
   }
   else { push @$out,@$source[$start..$start+$count-1] }
   JGraft::_Split->_append_meta($self,$source,$out,$offset,$start,$count) if $record && $record->{split};
   $self->_mark_date_container($out) if $record && $record->{may_have_dates};
}

sub _assign {
   my ($self,$trace,$value,$source)= @_;
   unless (ref($trace) eq 'HASH') {
      my $base=$self->{scratch_mem};
      local $self->{scratch_mem}=$base;
      local $self->{path_workspace}=[$base,0];
      return $self->_assign($self->_resolve($trace,'write'),$value,$source);
   }
   my $loc=$trace->{location};
   $self->_tick(1+@{$loc->[1]});
   if (($loc->[2] || '') eq 'node' || refaddr($loc->[0])==refaddr($self->{root})) {
      $value=$self->_export_dates($value,1,$self->{moving});
   }
   $trace=$self->_prepare_write($trace,'assign');
   unless (@{$loc->[1]}) { @{$loc->[0]}=($value,1); ++$self->{revision}; return }
   my $frame=$trace->{frames}[-1];
   my ($parent,$key)=@$frame[_F_CONTAINER,_F_KEY];
   if (ref $parent eq 'ARRAY' && !is_integer($key)) {
      my $rec=$self->_pending($parent);
      $self->_tick(4);
      $self->_move_scratch(56);
      # Pending values do not populate slots until finalization. Remember all
      # queued growth so an intervening append cannot consume its reservation.
      $self->_grow_array($parent,scalar(@$parent)+($rec->{insert_count} || 0)+1);
      $self->_reserve(0,96,0); # Final formatting row.
      my $row;
      $row=JGraft::_Split->_insert_meta($self,$parent,$source) if $source || $self->_split_meta($parent);
      push @{$rec->{insert}{0+$key}},$value;
      push @{$rec->{insert_meta}{0+$key}},$row;
      ++$rec->{insert_count};
   }
   else { $self->_set_member($parent,$key,$value,$source) }
   ++$self->{revision};
   if ($self->_contains_date($value)) {
      $self->_tick(scalar @{$trace->{frames}});
      $self->_mark_date_container($_->[_F_CONTAINER]) for @{$trace->{frames}};
   }
}
sub _splice {
   my ($self,$trace,$offset,$count,$values,$sources)=@_;
   my $loc=$trace->{location};
   my @parts=@{$loc->[1]};
   pop @parts;
   my $parent_loc=[$loc->[0],\@parts,$loc->[2]];
   my $size=scalar @{$trace->{frames}[-1][_F_CONTAINER]};
   $self->_tick($size+@$values);
   $self->_path_scratch(16*($size+@$values));
   $self->{undo_state}->_record($self,$parent_loc,0,$trace->{frames}) if $self->{undo_state};
   $trace=$self->_prepare_write($trace,'splice');
   my $array=$trace->{frames}[-1][_F_CONTAINER];
   $self->_grow_array($array,$size-$count+@$values);
   require JGraft::_Split;
   my $meta=JGraft::_Split->_splice_meta($self,$array,$offset,$count,$sources);
   splice @$array,$offset,$count,@$values;
   $self->_split_meta($array,$meta);
   JGraft::_Split->_fill_meta($self,$array,1) if $meta;
   ++$self->{revision};
   for my $value (@$values) {
      next unless $self->_contains_date($value);
      $self->_tick(scalar @{$trace->{frames}});
      $self->_mark_date_container($_->[_F_CONTAINER]) for @{$trace->{frames}};
      last;
   }
}

sub _pending {
   my ($self,$array)= @_;
   my $record=$self->_container($array,1);
   return $record->{pending} if $record->{pending};
   # Reserve the final compaction's work and scratch space before editing.
   my $metadata=$record->{split}?1:0;
   $self->_tick(($metadata?4:2)*@$array+1);
   $self->_move_scratch(224+16*@$array);
   $self->_reserve(0,96*@$array,0) if $metadata;
   # Only this batch holds the array strongly, and only until finalization.
   my $pending={array=>$array,deleted=>{},insert=>{},insert_meta=>{},metadata=>$metadata,record=>$record};
   $record->{pending}=$pending;
   push @{$self->{move_batch}},$pending;
   return $pending;
}
sub _remove {
   my ($self,$trace)=@_;
   $trace=$self->_prepare_write($trace,'remove');
   my $loc=$trace->{location};
   unless (@{$loc->[1]}) { $loc->[0][1]=0; ++$self->{revision}; return }
   my $frame=$trace->{frames}[-1];
   if ($frame->[_F_KIND]==TYPE_OBJECT) { delete $frame->[_F_CONTAINER]{$frame->[_F_KEY]} }
   else {
      my $pending=$self->_pending($frame->[_F_CONTAINER]);
      $self->_move_scratch(24);
      $pending->{deleted}{0+$frame->[_F_KEY]}=1;
   }
   ++$self->{revision};
}

sub _finish_moves {
   my $self=shift;
   # Work was charged on first deletion/insertion (and subsequent appends).
   for my $rec (@{$self->{move_batch}}) {
      my $array=$rec->{array};
      my (@out,@rows);
      my $meta=$rec->{record}{split};
      for my $i (0..$#$array) {
         push @out,@{$rec->{insert}{$i-.5} || []};
         push @rows,@{$rec->{insert_meta}{$i-.5} || []} if $meta;
         push @out,$array->[$i] unless $rec->{deleted}{0+$i};
         push @rows,$meta->{rows}[$i] if $meta && !$rec->{deleted}{0+$i};
      }
      push @out,@{$rec->{insert}{@$array-.5} || []};
      push @rows,@{$rec->{insert_meta}{@$array-.5} || []} if $meta;
      @$array=@out;
      ++$self->{revision};
      if ($meta) { $meta->{rows}=\@rows; JGraft::_Split->_fill_meta($self,$array,1) }
      delete $rec->{record}{pending};
      delete $rec->{record};
   }
   $self->{move_batch}=[];
}
sub _move {
   my ($self,$pairs,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{path_workspace}=[$scratch_base,0];
   local $self->{move_workspace}=0;
   local $self->{moving}=1;
   $self->_tick(scalar @$pairs);
   my $ok=eval {
      for my $pair (@$pairs) {
         # Previous pair vectors are gone; keep only the already checked queues
         # before reserving this pair's paths. Cleanup never needs a new check.
         $self->{path_workspace}[1]=$self->{move_workspace};
         $self->{scratch_mem}=$scratch_base+$self->{move_workspace};
         my $src=defined $pair->[0]? $self->_expand_path($pair->[0],'move_src',$depth+1):undef;
         my $dst=defined $pair->[1]? $self->_expand_path($pair->[1],'move_dst',$depth+1):undef;
         my $source=$src?$self->_resolve($src,'read',undef,1):undef;
         my $canonical=$source && $source->{location};
         my $value=$source && $source->{value};
         my $metadata=$source && $source->{source};
         my $destination=$dst?$self->_resolve($dst,'move_dst',$canonical):undef;
         my $dest=$destination && $destination->{location};
         if ($canonical && $dest && refaddr($canonical->[0])==refaddr($dest->[0])
            && @{$canonical->[1]}==@{$dest->[1]}) {
            my $same=1;
            $self->_tick(scalar @{$dest->[1]});
            for my $i (0..$#{$dest->[1]}) { $same=0 unless $self->_same_key($canonical->[1][$i],$dest->[1][$i]) }
            next if $same;
         }
         $self->_remove($source) if $source;
         $self->_assign($destination,$value,$metadata) if $destination;
      }
      $self->{current}[0][1] or $self->_fail('INVALID_TARGET','MOVE did not replace the current node');
      $self->_read_value($self->{current});
      1;
   };
   my $err=$@;
   $self->_finish_moves;
   die $err unless $ok;
}

# MOVE owns pending queues and their final compaction buffers through failure
# cleanup. Reserve growth before publishing any deferred edit.
sub _move_scratch {
   my ($self,$bytes)=@_;
   $self->{move_workspace}+=$bytes;
   $self->_path_scratch($bytes);
}

sub _date {
   my ($self,$value)=@_;
   require JGraft::Date;
   return $value if blessed($value) && $value->isa('JGraft::Date');
   my $id=ref($value)?refaddr($value):undef;
   return $self->{dates}{$id}[1] if defined($id) && $self->{dates}{$id};
   my $size=ref($value) eq 'HASH'? scalar keys %$value : 0;
   $self->_tick(16+$size+(type_mask($value)==TYPE_STRING?length($value)*.01:0));
   $self->_allocation(256+128*$size+(type_mask($value)==TYPE_STRING?8*length($value):0));
   my $date=eval { JGraft::Date->new($value) };
   unless ($date) {
      my $error=$@;
      die $error if ref $error;
      $self->_fail($error =~ /UNSUPPORTED_GRAFT:/?'UNSUPPORTED_GRAFT':'INVALID_TARGET',"Invalid date: $error");
   }
   if (defined $id) {
      $self->_reserve(0,128,0);
      $self->{dates}{$id}=[$value,$date];
   }
   return $date;
}
sub _contains_date {
   my ($self,$value)=@_;
   return 0 unless ref $value;
   return 1 if type_mask($value)==TYPE_DATE;
   my $record=$self->_container($value);
   return $record && $record->{may_have_dates};
}
sub _mark_date_container {
   my ($self,$value)=@_;
   my $record=$self->_container($value,1);
   return if $record->{may_have_dates};
   $self->_reserve(0,64,0);
   $record->{may_have_dates}=1;
}
sub _export_dates {
   my ($self,$value,$depth,$transfer)=@_;
   return $value unless $self->_contains_date($value);
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $workspace=[$scratch_base,128,{},$transfer?[]:undef];
   $self->_scratch_set($scratch_base,128);
   my $out=$self->_export_date_value($value,$depth,$workspace);
   # All conversion, capacity, and queue-copy checks finish before changing a
   # batch owner. Failure above leaves its original arrays available to cleanup.
   if ($transfer) {
      for my $plan (@{$workspace->[3]}) {
         my ($pending,$record,$array,$insert)=@$plan;
         delete $pending->{record}{pending};
         $pending->{record}=$record;
         $pending->{array}=$array;
         $pending->{insert}=$insert;
         $record->{pending}=$pending;
      }
   }
   return $out;
}
sub _export_date_value {
   my ($self,$value,$depth,$workspace)=@_;
   return $value unless $self->_contains_date($value);
   $self->_enter($depth);
   my $id=refaddr($value);
   if (type_mask($value)==TYPE_DATE) {
      return $self->{date_output}{$id}[1] if exists $self->{date_output}{$id};
      my $date=$self->_date($value);
      my $canonical=refaddr($date);
      return $self->{date_output}{$canonical}[1] if exists $self->{date_output}{$canonical};
      $self->_allocation(256+length($date->fraction));
      $self->_reserve(0,$id==$canonical?128:256,0);
      my $format=$self->{options}{date_format} || 'iso8601';
      my $out;
      if (ref($format) eq 'CODE') { $out=$format->($date) }
      else {
         my $ok=eval { $out=$date->format($format); 1 };
         $self->_fail('UNSUPPORTED_GRAFT',"Cannot export date: $@") unless $ok;
      }
      if (type_mask($out)==TYPE_STRING) {
         $self->_tick(length($out)*.001); $self->_reserve(0,4*length($out),0);
         $self->_check_string($out,'date output');
      }
      $self->{date_output}{$canonical}=[$date,$out];
      $self->{date_output}{$id}=[$value,$out] if $id!=$canonical;
      if (type_mask($out)==TYPE_DATE) {
         my $output_id=refaddr($out);
         if ($output_id!=$id && $output_id!=$canonical) {
            $self->_reserve(0,64+(exists($self->{date_output}{$output_id})?0:64),0);
            $self->{date_output}{$output_id}=[$out,$out];
         }
      }
      return $out;
   }
   my $memo=$workspace->[2];
   return $memo->{$id} if exists $memo->{$id};
   $workspace->[1]+=64;
   $self->_scratch_set(@$workspace[0,1]);
   # Choose the representation before allocation. Exact objects include hidden
   # duplicate members and never need a discarded ordinary-hash placeholder.
   my $tie=ref($value) eq 'HASH'?tied(%$value):undef;
   if ($tie && $tie->isa('JGraft::JSON::Object')) {
      my $out=$self->_own($tie->_clone(sub { $self->_export_date_value($_[0],$depth+1,$workspace) }));
      $memo->{$id}=$out;
      $self->_inherit_origin($value,$out) if $workspace->[3] && $self->{undo_state};
      return $out;
   }
   my $out=ref($value) eq 'ARRAY'? $self->_alloc_array(scalar @$value) : $self->_alloc_hash(scalar keys %$value);
   $memo->{$id}=$out;
   $self->_inherit_origin($value,$out) if $workspace->[3] && $self->{undo_state};
   if (ref($value) eq 'ARRAY') {
      $self->_tick(scalar @$value);
      for my $i (0..$#$value) {
         $self->_present($value,$i) or $self->_fail('INVALID_TARGET','Cannot export a deleted array element');
         $self->_set_member($out,$i,$self->_export_date_value($value->[$i],$depth+1,$workspace));
      }
      JGraft::_Split->_copy_meta($self,$value,$out,0,scalar @$value) if $self->_split_meta($value);
      my $record=$workspace->[3] && $self->_container($value);
      if ($record && $record->{pending}) {
         my $pending=$record->{pending};
         my $keys=keys %{$pending->{insert}};
         my $count=$pending->{insert_count} || 0;
         $workspace->[1]+=144+64*$keys+32*$count;
         $self->_scratch_set(@$workspace[0,1]);
         my $levels=1; ++$levels while 2**$levels<$keys;
         $self->_tick($keys*$levels+$count);
         $self->_grow_array($out,scalar(@$out)+$count);
         my %insert;
         for my $key (sort {$a<=>$b} keys %{$pending->{insert}}) {
            $insert{$key}=[map $self->_export_date_value($_,$depth+1,$workspace),@{$pending->{insert}{$key}}];
         }
         push @{$workspace->[3]},[$pending,$self->_container($out),$out,\%insert];
      }
   }
   else {
      my $keys_bytes=80+16*keys %$value;
      $workspace->[1]+=$keys_bytes;
      $self->_scratch_set(@$workspace[0,1]);
      $self->_tick(scalar keys %$value);
      for my $key (keys %$value) { $self->_set_member($out,$key,$self->_export_date_value($value->{$key},$depth+1,$workspace)) }
      $workspace->[1]-=$keys_bytes;
      $self->{scratch_mem}=$workspace->[0]+$workspace->[1];
   }
   return $out;
}

=head1 DESCRIPTION

Private methods on JGraft::Exec for resource accounting, container ownership,
inspection, path resolution, construction, mutation, and date representation.
Loaded by JGraft::Exec; there is no additional store object or public API.

=cut

1;
