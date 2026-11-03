package JGraft::Exec;
# VERSION
# ABSTRACT: Execute JGrafts with copy-on-write ownership
use strict;
use warnings;
no warnings 'recursion';
use Carp 'croak';
use Scalar::Util qw(blessed refaddr);
use JSON::PP ();
use JGraft::Util qw(type_mask is_finite is_integer is_expr is_action);
use overload '""' => 'as_string', 'bool' => sub { 1 }, fallback => 1;

sub new {
   my $class= shift;
   @_ % 2 == 0 or croak 'Expected name/value options';
   my %opt= @_;
   my %allowed= map {$_=>1} qw(jgraft input clone undo limits);
   $allowed{$_} or croak "Unknown execution option '$_'" for keys %opt;
   my %limits= (ops=>1000000, mem=>67108864, new_obj=>100000, depth=>256);
   if (exists $opt{limits}) {
      ref $opt{limits} eq 'HASH' or croak 'limits must be a hashref';
      for my $key (keys %{$opt{limits}}) {
         exists $limits{$key} or croak "Unknown resource limit '$key'";
         my $v= $opt{limits}{$key};
         !defined $v || (is_finite($v) && $v >= 0) or croak "Invalid $key limit";
         $limits{$key}= $v;
      }
   }
   return bless {options=>\%opt, limits=>\%limits}, $class;
}

sub output { $_[0]{output} }
sub error { $_[0]{error} }
sub message { $_[0]{message} }
sub diagnostic { $_[0]{diagnostic} }
sub success { $_[0]{success} }
sub undo {
   my $self=shift;
   @_ == 0 or croak 'undo takes no arguments';
   return $self->{undo} if exists $self->{undo};
   my $state=$self->{undo_state} or return;
   my $graft=$state->_build;
   $self->{undo}=$graft;
   delete $self->{undo_state};
   return $graft;
}
sub counters { +{%{$_[0]{count} || {}}} }
sub as_string { my $s=shift; $s->{error}? "$s->{error}: $s->{message}" : 'JGraft execution context' }

sub apply {
   my $self= shift;
   @_ <= 1 or croak 'Expected at most one input value';
   @_ || exists $self->{options}{input} or croak 'No input provided';
   my $input= @_? $_[0] : $self->{options}{input};
   delete @{$self}{qw(error message diagnostic success undo output)};
   $self->{count}= {ops=>0,mem=>0,new_obj=>0,depth=>0};
   $self->{owned}= {};
   $self->{lineage}= {};
   delete $self->{undo_state};
   $self->{pending}= {};
   $self->{epoch}= 1;
   $self->{root}= [$input,1];
   $self->{current}= [$self->{root},[]];
   my $ok= eval {
      if ($self->{options}{undo}) {
         require JGraft::_Undo;
         $self->{undo_state}= JGraft::_Undo->_new($self,$input);
         $self->_charge('mem',192);
      }
      $self->_inspect($input,1,{},0,0);
      $self->{temp}= [$self->_new_hash(0),1];
      $self->{stash}= [$self->_new_hash(0),1];
      $self->{const}= [$self->_new_hash(0),1];
      $self->{expr}= [$self->_new_hash(0),1];
      $self->{cap}= [$self->_new_hash(0),1];
      my $graft= $self->{options}{jgraft};
      $self->_inspect($graft,1,{},1,!is_action($graft));
      unless (is_action($graft)) {
         require JGraft;
         my $parsed= eval { JGraft::jgparse($graft) };
         my $err= $@;
         $err and $self->_fail('INVALID_GRAFT',"$err",$err);
         $graft= $parsed;
      }
      $self->_run($graft,1);
      $self->{root}[1] or $self->_fail('INVALID_TARGET','Current node was deleted without replacement');
      $self->{output}= $self->{options}{clone}
         ? $self->_clone_tree($self->{root}[0],1) : $self->{root}[0];
      $self->{success}= 1;
      1;
   };
   my $err=$@;
   $self->{undo_state}{output}= $ok? $self->{output}
      : $self->{root}[1]? $self->{root}[0] : undef if $self->{undo_state};
   unless ($ok) {
      die $err unless blessed($err) && refaddr($err) == refaddr($self);
      $self->{output}= $self->{root}[0] if $self->{root}[1];
      return;
   }
   return $self->{output};
}

sub _fail {
   my ($self,$code,$message,$cause)= @_;
   $self->{error}= $code;
   $self->{message}= $message;
   $self->{diagnostic}= { action=>$self->{action}, expression=>$self->{expression},
      path=>[ @{$self->{current}[1]} ] };
   $self->{diagnostic}{cause}=$cause if defined $cause;
   die $self;
}
sub _charge {
   my ($self,$key,$amount)= @_;
   $self->{count}{$key} += $amount;
   my $limit= $self->{limits}{$key};
   !defined $limit || $self->{count}{$key} <= $limit
      or $self->_fail('RESOURCE_LIMIT',"$key limit exceeded");
}
sub _step { $_[0]->_charge('ops',$_[1]) }
sub _depth {
   my ($self,$depth)= @_;
   if ($depth > $self->{count}{depth}) {
      $self->_charge('depth',$depth-$self->{count}{depth});
   }
}
sub _allocation {
   my ($self,$bytes)= @_;
   $self->_charge('new_obj',1);
   $self->_charge('mem',$bytes+64);
}
sub _own {
   my ($s,$v)=@_;
   my $id=refaddr($v);
   $s->{owned}{$id}=$s->{epoch};
   if ($s->{undo_state}) {
      $s->_charge('mem',32);
      $s->{lineage}{$id}=$id;
   }
   $v;
}
sub _new_hash { my ($s,$n)=@_;$s->_allocation(128+64*$n);$s->_own({}) }
sub _new_array { my ($s,$n)=@_;$s->_allocation(80+16*$n);$s->_own([]) }

sub _inspect {
   my ($self,$v,$depth,$active,$ast,$alloc)= @_;
   $self->_depth($depth);
   $self->_step(1);
   if ($ast && (is_action($v) || is_expr($v))) {
      my $id= refaddr($v);
      $active->{$id} and $self->_fail('INVALID_GRAFT','Cyclic graft');
      local $active->{$id}=1;
      my @keys= grep $_ ne '_form', keys %$v;
      $self->_step(scalar @keys);
      $self->_inspect($v->{$_},$depth+1,$active,1,$alloc) for @keys;
      return;
   }
   my $type= type_mask($v);
   if (!ref $v || JSON::PP::is_bool($v)) {
      $self->_step(length($v)*.001) if $type == 8;
      $type != 4 || is_finite($v) or $self->_fail('UNSUPPORTED_GRAFT','Non-finite input number');
      return;
   }
   ref($v) eq 'ARRAY' || ref($v) eq 'HASH' or $self->_fail('UNSUPPORTED_GRAFT','Unsupported data reference '.ref($v));
   my $id=refaddr($v);
   $active->{$id} and $self->_fail($ast?'INVALID_GRAFT':'INVALID_TARGET','Cyclic data');
   local $active->{$id}=1;
   my $n= $type==16? scalar @$v : scalar keys %$v;
   if (!$ast && $self->{undo_state} && !$self->{undo_state}{original_ids}{$id}) {
      $self->_charge('mem',32);
      $self->{undo_state}{original_ids}{$id}=1;
   }
   $self->_step($n);
   $self->_allocation(($type==16?80:128)+($type==16?16:64)*$n) if $alloc;
   if ($type==16) {
      for my $i (0..$#$v) {
         exists $v->[$i] or $self->_fail('UNSUPPORTED_GRAFT','Sparse input arrays are not JSON data');
         $self->_inspect($v->[$i],$depth+1,$active,$ast,$alloc);
      }
   }
   else {
      for my $key (keys %$v) {
         $self->_step(length($key)*.001);
         $self->_inspect($v->{$key},$depth+1,$active,$ast,$alloc);
      }
   }
}

sub _cow {
   my ($self,$v)= @_;
   return $v if ($self->{owned}{refaddr($v)} || 0) == $self->{epoch};
   if (ref $v eq 'ARRAY') {
      my $copy=$self->_new_array(scalar @$v);
      $self->_step(scalar @$v);
      @$copy=@$v;
      $self->{lineage}{refaddr($copy)}=$self->{lineage}{refaddr($v)} || refaddr($v) if $self->{undo_state};
      return $copy;
   }
   my $copy=$self->_new_hash(scalar keys %$v);
   $self->_step(scalar keys %$v);
   %$copy=%$v;
   $self->{lineage}{refaddr($copy)}=$self->{lineage}{refaddr($v)} || refaddr($v) if $self->{undo_state};
   return $copy;
}
sub _snapshot {
   my ($self,$v)= @_;
   # Existing owned descendants can occur anywhere in a logical copy. Freezing
   # the generation avoids traversing that subtree to invalidate ownership.
   ++$self->{epoch} if ref($v) eq 'ARRAY' || ref($v) eq 'HASH';
   return $v;
}
sub _clone_tree {
   my ($self,$v,$depth)= @_;
   $self->_depth($depth);
   $self->_step(1);
   return $v unless ref $v eq 'ARRAY' || ref $v eq 'HASH';
   if (ref $v eq 'ARRAY') {
      my $out=$self->_new_array(scalar @$v);
      $self->{lineage}{refaddr($out)}=$self->{lineage}{refaddr($v)} || refaddr($v) if $self->{undo_state};
      $self->_step(scalar @$v);
      for my $i (0..$#$v) { $out->[$i]=$self->_clone_tree($v->[$i],$depth+1) }
      return $out;
   }
   my $out=$self->_new_hash(scalar keys %$v);
   $self->{lineage}{refaddr($out)}=$self->{lineage}{refaddr($v)} || refaddr($v) if $self->{undo_state};
   $self->_step(scalar keys %$v);
   $out->{$_}=$self->_clone_tree($v->{$_},$depth+1) for keys %$v;
   return $out;
}

sub _run {
   my ($self,$action,$depth)= @_;
   $self->_depth($depth);
   $self->_step(1);
   is_action($action) or $self->_fail('INVALID_GRAFT','Expected an action object');
   local $self->{action}=$action;
   local $self->{temp}=[$self->_new_hash(0),1];
   my $name=$action->_name;
   if ($name eq 'JGRAFT') {
      my $meta=$action->metadata;
      if (exists $meta->{v} && $meta->{v}>1) { $self->_fail('UNSUPPORTED_GRAFT','Unsupported JGraft version') }
      local $self->{const}= $self->{const};
      local $self->{expr}= $self->{expr};
      for my $ns ('const','expr') {
         next unless exists $meta->{$ns};
         my $copy=$self->_new_hash(scalar keys %{$self->{$ns}[0]});
         $self->_step(scalar keys %{$self->{$ns}[0]});
         %$copy=%{$self->{$ns}[0]};
         $self->{$ns}=[$copy,1];
         my $defs=$meta->{$ns};
         $self->_step(scalar @$defs);
         for (my $i=0;$i<@$defs;$i+=2) {
            my $key=$defs->[$i];
            $key="$key";
            my $v=$ns eq 'const'? $self->_eval($defs->[$i+1],$depth+1) : $defs->[$i+1];
            $self->_snapshot($v) if $ns eq 'const';
            $self->_write([$self->{$ns},[$key]],$v);
         }
      }
      local $self->{stash}=[$self->_new_hash(0),1];
      $self->_step(scalar @{$action->actions});
      $self->_run($_,$depth+1) for @{$action->actions};
   }
   elsif ($name eq 'AT') {
      my $loc=$self->_path($action->path,'at',$depth+1);
      my ($v,$canonical)=$self->_read($loc);
      local $self->{current}=$canonical;
      $self->_step(scalar @{$action->actions});
      $self->_run($_,$depth+1) for @{$action->actions};
   }
   elsif ($name eq 'COPY') {
      my $pairs=$action->assignments;
      $self->_step(scalar @$pairs);
      for my $pair (@$pairs) {
         my $v=$self->_eval($pair->[0],$depth+1);
         # Keep the value stable even if destination expressions read from it.
         $self->_snapshot($v);
         my $loc=$self->_path($pair->[1],'write',$depth+1);
         my $dest=$self->_probe($loc,undef,0);
         $self->_write($dest,$v);
      }
   }
   elsif ($name eq 'MOVE') { $self->_move($action->moves,$depth+1) }
   else { $self->_fail('UNSUPPORTED_GRAFT',"Action $name is not implemented") }
}

sub _path {
   my ($self,$expr,$mode,$depth)= @_;
   $self->_depth($depth);
   $self->_step(1);
   is_expr($expr) or $self->_fail('INVALID_OPERAND','Path must be a reference expression');
   if ($expr->_name eq 'EXPR') {
      return $self->_path($self->_macro($expr,$depth+1),$mode,$depth+1);
   }
   $expr->is_ref && exists $expr->{path} or $self->_fail('INVALID_OPERAND','Path must be a reference');
   my $ns=lc($expr->_name);
   if ($mode eq 'at') { $ns eq 'node' or $self->_fail('INVALID_OPERAND','AT must use NODE') }
   if ($mode eq 'write' || $mode eq 'move_src' || $mode eq 'move_dst') {
      $ns =~ /\A(?:node|temp|stash)\z/ or $self->_fail('INVALID_OPERAND','Read-only namespace');
   }
   my $base=$ns eq 'node'? $self->{current} : [$self->{$ns},[]];
   defined $base->[0] or $self->_fail('INVALID_OPERAND','Unknown namespace');
   my (@parts,@literal);
   $self->_step(scalar @{$expr->path});
   for my $part (@{$expr->path}) {
      my $value=$self->_eval($part,$depth+1);
      if (ref $value eq 'ARRAY') {
         $self->_step(scalar @$value);
         for my $i (0..$#$value) {
            $self->_present($value,$i) or $self->_fail('INVALID_TARGET','Path expands a deleted element');
            push @parts,$value->[$i];
            push @literal,!is_expr($part) && !is_expr($part->[$i]);
         }
      }
      else { push @parts,$value; push @literal,!is_expr($part) }
   }
   $self->_step(scalar @parts);
   for my $i (0..$#parts) {
      my $v=$parts[$i];
      my $t=type_mask($v);
      next if $t==8 || ($t==2 && !$v);
      if ($t==4 && is_finite($v)) {
         next if is_integer($v) || ($mode eq 'move_dst' && $i==$#parts && $v*2==int($v*2));
      }
      $self->_fail($literal[$i]?'INVALID_GRAFT':'INVALID_OPERAND','Invalid path selector');
   }
   $ns eq 'temp' && !@parts and $self->_fail('INVALID_OPERAND','TEMP root is inaccessible');
   if ($ns ne 'node' && ($mode eq 'write' || $mode =~ /^move_/) && !@parts) {
      $self->_fail((grep is_expr($_), @{$expr->path})?'INVALID_OPERAND':'INVALID_GRAFT','Namespace root cannot be overwritten or moved');
   }
   if ($ns ne 'node' && @parts && type_mask($parts[0])==4) {
      is_integer($parts[0]) or $self->_fail('INVALID_OPERAND','Namespace property must be an integer or string');
      my $key=$parts[0];
      $parts[0]="$key";
   }
   $self->_charge('mem',32+16*(@parts+@{$base->[1]}));
   return [$base->[0],[@{$base->[1]},@parts]];
}

sub _selector {
   my ($self,$value,$container,$half)= @_;
   my $type=type_mask($value);
   my $kind=type_mask($container);
   if ($kind==32) {
      $type==8 or $self->_fail('INVALID_TARGET','Object selectors must be strings');
      return $value;
   }
   $kind==16 or $self->_fail('INVALID_TARGET','Path descends through a scalar');
   my $len=@$container;
   return $len if $type==2 && !$value;
   $type==4 && is_finite($value) or $self->_fail('INVALID_TARGET','Array selectors must be numbers');
   if (is_integer($value)) {
      my $index=$value<0? $len+$value : 0+$value;
      $index>=0 && $index<=$len or $self->_fail('INVALID_TARGET','Array index out of range');
      return $index;
   }
   $half && $value*2==int($value*2) or $self->_fail('INVALID_OPERAND','Invalid fractional selector');
   my $index=$value<-.5? $len+$value : 0+$value;
   $index>=-.5 && $index<=$len-.5 or $self->_fail('INVALID_TARGET','Array insertion out of range');
   return $index;
}
sub _present {
   my ($self,$v,$key)= @_;
   return exists $v->{$key} if ref $v eq 'HASH';
   return 0 unless is_integer($key) && $key>=0 && $key<@$v && exists $v->[$key];
   my $record=$self->{pending}{refaddr($v)};
   return !$record || !$record->{deleted}{0+$key};
}
sub _child { ref $_[1] eq 'ARRAY'? $_[1][$_[2]] : $_[1]{$_[2]} }
sub _read {
   my ($self,$loc)= @_;
   my ($cell,$parts)=@$loc;
   $self->_step(1+@$parts);
   $self->_depth(1+@$parts);
   $cell->[1] or $self->_fail('INVALID_TARGET','Current node does not exist');
   my $v=$cell->[0];
   my @canonical;
   for my $part (@$parts) {
      my $key=$self->_selector($part,$v,0);
      $self->_present($v,$key) or $self->_fail('INVALID_TARGET','Path does not exist');
      push @canonical,$key;
      $v=$self->_child($v,$key);
   }
   return ($v,[$cell,\@canonical]);
}
sub _same_key {
   my ($self,$a,$b)= @_;
   return 0 unless type_mask($a)==type_mask($b);
   $self->_step(1+(length($a)+length($b))*.001) if type_mask($a)==8;
   return $a eq $b;
}
sub _probe {
   my ($self,$loc,$removed,$half)= @_;
   my ($cell,$parts)=@$loc;
   $self->_step(1+@$parts);
   $self->_depth(1+@$parts);
   my $match=$removed && refaddr($removed->[0])==refaddr($cell);
   my $exists=$cell->[1] && !($match && !@{$removed->[1]});
   my $v=$cell->[0];
   my @canonical;
   for my $i (0..$#$parts) {
      unless ($exists) {
         # These empty virtual containers are for validation, not output.
         my $kind=type_mask($parts->[$i]);
         $v=$kind==8? {} : [];
      }
      my $key=$self->_selector($parts->[$i],$v,$half && $i==$#$parts);
      if (ref $v eq 'ARRAY' && !is_integer($key)) {
         push @canonical,$key;
         last;
      }
      my $present=$exists && $self->_present($v,$key);
      if ($match) {
         $match= $i<@{$removed->[1]} && $self->_same_key($key,$removed->[1][$i]);
         $present=0 if $match && $i==$#{$removed->[1]};
      }
      push @canonical,$key;
      $v=$present? $self->_child($v,$key) : undef;
      $exists=$present;
   }
   return [$cell,\@canonical];
}

sub _parent {
   my ($self,$loc)= @_;
   my ($cell,$parts)=@$loc;
   if (!$cell->[1]) {
      $cell->[0]=type_mask($parts->[0])==8? $self->_new_hash(0):$self->_new_array(0);
      $cell->[1]=1;
   }
   my $v=$self->_cow($cell->[0]);
   $cell->[0]=$v;
   for my $i (0..$#$parts-1) {
      my $key=$parts->[$i];
      my $child;
      if ($self->_present($v,$key)) { $child=$self->_child($v,$key) }
      else { $child=type_mask($parts->[$i+1])==8? $self->_new_hash(0):$self->_new_array(0) }
      $child=$self->_cow($child);
      $self->_put($v,$key,$child);
      $v=$child;
   }
   return ($v,$parts->[-1]);
}
sub _put {
   my ($self,$parent,$key,$value)= @_;
   if (ref $parent eq 'HASH') {
      $self->_charge('mem',64+length($key)) unless exists $parent->{$key};
      $parent->{$key}=$value;
   }
   else {
      my $rec=$self->{pending}{refaddr($parent)};
      if ($key==@$parent) {
         $self->_charge('mem',16);
         if ($rec) { $self->_step(2); $self->_charge('mem',16) }
      }
      delete $rec->{deleted}{0+$key} if $rec;
      $parent->[$key]=$value;
   }
}
sub _write {
   my ($self,$loc,$value)= @_;
   $self->_step(1+@{$loc->[1]});
   $self->{undo_state}->_record($self,$loc) if $self->{undo_state};
   unless (@{$loc->[1]}) { @{$loc->[0]}=($value,1); return }
   my ($parent,$key)=$self->_parent($loc);
   if (ref $parent eq 'ARRAY' && !is_integer($key)) {
      my $rec=$self->_pending($parent);
      $self->_step(1);
      $self->_charge('mem',40);
      push @{$rec->{insert}{0+$key}},$value;
   }
   else { $self->_put($parent,$key,$value) }
}
sub _pending {
   my ($self,$array)= @_;
   my $id=refaddr($array);
   return $self->{pending}{$id} if $self->{pending}{$id};
   # Reserve the final compaction's work and scratch space before editing.
   $self->_step(2*@$array+1);
   $self->_charge('mem',192+16*@$array);
   return $self->{pending}{$id}={array=>$array,deleted=>{},insert=>{}};
}
sub _delete {
   my ($self,$loc)= @_;
   $self->{undo_state}->_record($self,$loc,1) if $self->{undo_state};
   unless (@{$loc->[1]}) { $loc->[0][1]=0; return }
   my ($parent,$key)=$self->_parent($loc);
   if (ref $parent eq 'HASH') { delete $parent->{$key} }
   else {
      my $rec=$self->_pending($parent);
      $self->_charge('mem',24);
      $rec->{deleted}{0+$key}=1;
   }
}
sub _finish_moves {
   my $self=shift;
   # Work was charged on first deletion/insertion (and subsequent appends).
   for my $rec (values %{$self->{pending}}) {
      my $array=$rec->{array};
      my @out;
      for my $i (0..$#$array) {
         push @out,@{$rec->{insert}{$i-.5} || []};
         push @out,$array->[$i] unless $rec->{deleted}{0+$i};
      }
      push @out,@{$rec->{insert}{@$array-.5} || []};
      @$array=@out;
   }
   $self->{pending}={};
}
sub _move {
   my ($self,$pairs,$depth)= @_;
   $self->_step(scalar @$pairs);
   my $ok=eval {
      for my $pair (@$pairs) {
         my $src=defined $pair->[0]? $self->_path($pair->[0],'move_src',$depth+1):undef;
         my $dst=defined $pair->[1]? $self->_path($pair->[1],'move_dst',$depth+1):undef;
         my ($value,$canonical)= $src? $self->_read($src) : (undef,undef);
         my $dest=$dst? $self->_probe($dst,$canonical,1) : undef;
         if ($canonical && $dest && refaddr($canonical->[0])==refaddr($dest->[0])
            && @{$canonical->[1]}==@{$dest->[1]}) {
            my $same=1;
            $self->_step(scalar @{$dest->[1]});
            for my $i (0..$#{$dest->[1]}) { $same=0 unless $self->_same_key($canonical->[1][$i],$dest->[1][$i]) }
            next if $same;
         }
         $self->_delete($canonical) if $canonical;
         $self->_write($dest,$value) if $dest;
      }
      $self->{current}[0][1] or $self->_fail('INVALID_TARGET','MOVE did not replace the current node');
      $self->_read($self->{current});
      1;
   };
   my $err=$@;
   $self->_finish_moves;
   die $err unless $ok;
}

sub _macro {
   my ($self,$expr,$depth)= @_;
   my $name=$self->_eval($expr->name,$depth+1);
   my $t=type_mask($name);
   $t==8 || ($t==4 && is_integer($name)) or $self->_fail('INVALID_OPERAND','Invalid EXPR name');
   my $key="$name";
   exists $self->{expr}[0]{$key} or $self->_fail('INVALID_TARGET','Unknown common expression');
   return $self->{expr}[0]{$key};
}
sub _eval {
   my ($self,$v,$depth)= @_;
   $self->_depth($depth);
   $self->_step(1);
   if (is_expr($v)) {
      local $self->{expression}=$v;
      return $self->_expression($v,$depth);
   }
   my $t=type_mask($v);
   if ($t==16) {
      my $out=$self->_new_array(scalar @$v);
      $self->_step(scalar @$v);
      for my $i (0..$#$v) { $out->[$i]=$self->_eval($v->[$i],$depth+1) }
      return $out;
   }
   if ($t==32) {
      my $out=$self->_new_hash(scalar keys %$v);
      $self->_step(scalar keys %$v);
      $out->{$_}=$self->_eval($v->{$_},$depth+1) for keys %$v;
      return $out;
   }
   $self->_step(length($v)*.001) if $t==8;
   $t==1 || $t==2 || $t==4 || $t==8 or $self->_fail('UNSUPPORTED_GRAFT','Unsupported literal value');
   return $v;
}
sub _input_value {
   my ($self,$expr,$field,$depth)= @_;
   return $self->_eval($expr->{$field},$depth+1) if exists $expr->{$field};
   return ($self->_read($self->{current}))[0];
}
sub _expression {
   my ($self,$expr,$depth)= @_;
   my $name=$expr->_name;
   return $self->_eval($self->_macro($expr,$depth+1),$depth+1) if $name eq 'EXPR';
   return ($self->_read($self->_path($expr,'read',$depth+1)))[0] if $expr->is_ref;
   if ($name eq 'FAIL') { $self->_fail('INVALID_TARGET','FAIL expression') }
   if ($name eq 'LENGTH') {
      my $v=$self->_input_value($expr,'value_expr',$depth);
      my $t=type_mask($v);
      return scalar @$v if $t==16;
      if ($t==8) { $self->_step(length($v)*.001); return length($v) }
      $self->_fail('INVALID_TARGET','LENGTH expects an array or string');
   }
   if ($name eq 'SLICE') { return $self->_slice($expr,$depth+1) }
   if ($name eq 'LOCAL') {
      my $copy=$self->_new_hash(scalar keys %{$self->{temp}[0]});
      $self->_step(scalar keys %{$self->{temp}[0]});
      %$copy=%{$self->{temp}[0]};
      local $self->{temp}=[$copy,1];
      local $self->{current}=$self->{current};
      $self->_step(scalar @{$expr->bindings});
      for my $pair (@{$expr->bindings}) {
         my $key=$self->_eval($pair->[0],$depth+1);
         my $t=type_mask($key);
         $t==1 || $t==8 || ($t==4 && is_finite($key)) or $self->_fail('INVALID_OPERAND','Invalid LOCAL property');
         my $value=$self->_eval($pair->[1],$depth+1);
         if (!defined $key) { $self->{current}=[[$value,1],[]] }
         else { $self->{temp}[0]{"$key"}=$value }
      }
      return $self->_eval($expr->return_value_expr,$depth+1);
   }
   if ($name eq 'AND' || $name eq 'OR' || $name eq 'NOT') {
      $self->_step(scalar @{$expr->value_exprs});
      for my $arg (@{$expr->value_exprs}) {
         my $v=$self->_eval($arg,$depth+1);
         type_mask($v)==2 or $self->_fail('INVALID_TARGET','Logical operands must be booleans');
         return JSON::PP::false if $name eq 'AND' && !$v;
         return $name eq 'NOT'? JSON::PP::false : JSON::PP::true if $name ne 'AND' && $v;
      }
      return $name eq 'OR'? JSON::PP::false : JSON::PP::true;
   }
   if ($name eq 'CASTBOOL' || $name eq 'CASTNUM' || $name eq 'CASTSTR') {
      my $v=$self->_input_value($expr,'value_expr',$depth);
      my $t=type_mask($v);
      if ($name eq 'CASTBOOL') {
         return $v if $t==2;
         return $v? JSON::PP::true : JSON::PP::false if $t==4 && ($v==0 || $v==1);
         return $v eq 'true'? JSON::PP::true : JSON::PP::false if $t==8 && ($v eq 'true' || $v eq 'false');
      }
      elsif ($name eq 'CASTNUM') {
         return $v if $t==4;
         if ($t==8 && $v =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/) {
            $self->_step(length($v)*.001);
            my $num=0+$v;
            is_finite($num) or $self->_fail('UNSUPPORTED_GRAFT','Number outside supported range');
            return $num;
         }
      }
      else {
         return $v if $t==8;
         return $v? 'true':'false' if $t==2;
         if ($t==4) {
            require JGraft;
            return JGraft::_json()->new->allow_nonref->encode($v);
         }
      }
      $self->_fail('INVALID_TARGET',"Invalid $name input");
   }
   if ($name eq 'ADD' || $name eq 'MUL' || $name eq 'SUB' || $name eq 'DIV' || $name eq 'MOD') {
      my @values;
      if (exists $expr->{value_exprs}) {
         $self->_step(scalar @{$expr->value_exprs});
         @values=map $self->_eval($_,$depth+1), @{$expr->value_exprs};
         if (@values==1 && ref $values[0] eq 'ARRAY') {
            my $array=$values[0];
            $self->_step(scalar @$array);
            for my $i (0..$#$array) { $self->_present($array,$i) or $self->_fail('INVALID_TARGET','Deleted array element') }
            @values=@$array;
         }
      }
      else { @values=map $self->_eval($expr->{$_},$depth+1), qw(value_expr1 value_expr2) }
      $self->_step(scalar @values);
      for my $v (@values) { type_mask($v)==4 && is_finite($v) or $self->_fail('INVALID_TARGET','Arithmetic expects finite numbers') }
      my $result=$name eq 'MUL'?1:0;
      if ($name eq 'ADD') { $result+=$_ for @values }
      elsif ($name eq 'MUL') { $result*=$_ for @values }
      elsif ($name eq 'SUB') { $result=$values[0]-$values[1] }
      else {
         $values[1]!=0 or $self->_fail('INVALID_TARGET','Division by zero');
         if ($name eq 'DIV') { $result=$values[0]/$values[1] }
         else { require POSIX; $result=$values[0]-POSIX::floor($values[0]/$values[1])*$values[1] }
      }
      is_finite($result) or $self->_fail('INVALID_TARGET','Non-finite arithmetic result');
      return $result;
   }
   $self->_fail('UNSUPPORTED_GRAFT',"Expression $name is not implemented");
}

sub _slice {
   my ($self,$expr,$depth)= @_;
   my ($value,$ofs,$len,$lim);
   if (exists $expr->{config_obj}) {
      my $config=$self->_eval($expr->config_obj,$depth+1);
      ref $config eq 'HASH' or $self->_fail('INVALID_OPERAND','SLICE config must be an object');
      for my $key (qw(ofs len lim)) {
         next unless exists $config->{$key};
         is_integer($config->{$key}) && $config->{$key}>=0 or $self->_fail('INVALID_OPERAND','Invalid SLICE bound');
      }
      if (exists $config->{path}) {
         ref $config->{path} eq 'ARRAY' or $self->_fail('INVALID_OPERAND','SLICE path must be an array');
         require JGraft;
         $value=($self->_read($self->_path(JGraft::NODE($config->{path}),'read',$depth+1)))[0];
      }
      else { $value=($self->_read($self->{current}))[0] }
      ($ofs,$len,$lim)=@{$config}{qw(ofs len lim)};
      if (defined $ofs && defined $len && defined $lim && $ofs+$len!=$lim) { $self->_fail('INVALID_OPERAND','Inconsistent SLICE bounds') }
      $ofs=defined $len && defined $lim? $lim-$len : 0 unless defined $ofs;
   }
   else {
      $value=$self->_eval($expr->value_expr,$depth+1);
      $ofs=$self->_eval($expr->ofs,$depth+1);
      $len=$self->_eval($expr->len,$depth+1) if exists $expr->{len};
      is_integer($ofs) && (!exists $expr->{len} || is_integer($len)) or $self->_fail('INVALID_OPERAND','SLICE bounds must be integers');
   }
   my $type=type_mask($value);
   $type==16 || $type==8 or $self->_fail('INVALID_TARGET','SLICE expects an array or string');
   my $size=$type==16? scalar @$value : length($value);
   $ofs+=$size if $ofs<0;
   $lim=defined $len? ($len<0?$size+$len:$ofs+$len) : $size unless defined $lim;
   $ofs>=0 && $ofs<=$lim && $lim<=$size or $self->_fail('INVALID_TARGET','SLICE is out of range');
   if ($type==8) { $self->_step(($lim-$ofs)*.001); $self->_charge('mem',4*($lim-$ofs)); return substr($value,$ofs,$lim-$ofs) }
   my $out=$self->_new_array($lim-$ofs);
   $self->_step($lim-$ofs);
   for (my $i=$ofs;$i<$lim;++$i) {
      $self->_present($value,$i) or $self->_fail('INVALID_TARGET','SLICE contains a deleted element');
      push @$out,$value->[$i];
   }
   return $out;
}

=head1 SYNOPSIS

  my $exec= JGraft::Exec->new(jgraft => $graft, undo => 1);
  my @result= $exec->apply($input);
  die $exec unless @result;
  my $output= $result[0];

=head1 DESCRIPTION

Executes JGRAFT, AT, COPY, and MOVE with namespace references, value construction,
common expressions, LOCAL, LENGTH, SLICE, arithmetic, logical operators, and the
boolean/number/string casts. Other operations fail with UNSUPPORTED_GRAFT.

Unchanged subtrees may share storage with input. New containers are owned by an
execution generation. Copying a container freezes that generation; subsequent
writes shallow-clone the affected path. This also separates logical copies of
containers created earlier in the same execution. MOVE transfers ownership and
keeps deferred deletions/insertions attached to array identity until its end.

=constructor new

Options: C<jgraft>, optional C<input>, C<clone>, C<undo>, and C<limits>. Limits
are estimated cumulative C<ops>, C<mem>, C<new_obj>, and maximum C<depth>. Defaults
are 1,000,000 operations, 64 MiB, 100,000 data containers, and depth 256. An explicit
undef disables an individual limit. Memory accounting is a conservative cumulative
allocation estimate including path and deferred-array scratch space; it does not
subtract reclaimed storage. Input and pre-existing graft containers are excluded
from new allocations. JSON-data graft compilation is conservatively precharged.

=method apply

Apply to one input value, or the constructor's input when omitted. In list context
success returns one value, including null/zero/false; failure returns an empty list.
In scalar context null success and failure both return undef; use C<success> or
C<error> to distinguish them. Expected failures populate this object; unexpected
implementation exceptions propagate. Each application resets execution state.

=attribute output

The result, or isolated partial output on failure. The original input is preserved.
With C<clone>, all result containers are detached from input and repeated subtree
occurrences become separate containers. Treat shared input/output as read-only
outside the executor unless this option is selected.

=attribute error

An error code, or undef after success.

=attribute message

The diagnostic text for an expected failure.

=attribute diagnostic

The action, expression, and current path recorded at failure.
For graft parsing failures, C<cause> preserves the original exception, including
L<JGraft::Error> construction context and its text stack trace.

=attribute success

True after successful execution, including when the result is null.

=attribute counters

A copy of the resource counters. new_obj counts allocated data containers; metadata
and temporary work are included in memory/operation estimates.

=method undo

  my $undo= $exec->undo;

With C<< undo => 1 >>, lazily builds and caches a graft restoring the original
from the result or partial output. Execution records altered paths; calculation
collapses repeated writes and skips untouched branches. Added subtrees are removed,
deleted values are retained, and relocated containers can be recovered through
references to the output. Array edits preserve stable spans where possible.
Nested AT scopes keep paths relative and share prefixes for relocated subtrees.
The result is proportional to the net edits and lost data, rather than the whole
input; it is not guaranteed to be the smallest possible graft.

Until first called, the original and output are retained for calculation and must
remain read-only. Afterwards only values needed by the cached graft are retained.
Returns undef when undo was not enabled or no application has started.

Calculation runs without resource limits and leaves the execution's status,
diagnostic, and counters intact. Applying the returned graft is an ordinary
execution with its own fresh limits.

=method as_string

Stringify the context as its error code and message, or its success description.

=cut

1;
