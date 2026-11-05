package JGraft::Exec;
# VERSION
# ABSTRACT: Execute JGrafts with copy-on-write ownership
use strict;
use warnings;
no warnings 'recursion';
use Carp 'croak';
use Scalar::Util qw(blessed refaddr weaken);
use JSON::PP ();
use JGraft::Util qw(:types type_mask is_finite is_integer is_expr is_action);
use overload '""' => 'as_string', 'bool' => sub { 1 }, fallback => 1;

sub new {
   my $class= shift;
   @_ % 2 == 0 or croak 'Expected name/value options';
   my %opt= @_;
   my %allowed= map {$_=>1} qw(jgraft input clone undo limits codepoint_policy date_format);
   $allowed{$_} or croak "Unknown execution option '$_'" for keys %opt;
   if (exists $opt{date_format}) {
      my $format=$opt{date_format};
      defined($format) && (ref($format) eq 'CODE' || (!ref($format) && $format =~ /\A(?:iso8601|Time::Piece|DateTime)\z/))
         or croak 'date_format must be iso8601, Time::Piece, DateTime, or a coderef';
   }
   if (exists $opt{codepoint_policy}) {
      my $policy=$opt{codepoint_policy};
      defined($policy) && (ref($policy) eq 'CODE' || (!ref($policy) && $policy =~ /\A(?:preserve|reject|substitute)\z/))
         or croak 'codepoint_policy must be preserve, reject, substitute, or a coderef';
   }
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
sub logs { $_[0]{logs} || [] }
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
   $self->{logs}= [];
   $self->{owned}= {};
   $self->{lineage}= {};
   delete $self->{undo_state};
   $self->{pending}= {};
   $self->{regex_literals}= {};
   $self->{char_classes}= {};
   $self->{split_meta}= {};
   $self->{split_origin}= 0;
   $self->{dates}= {};
   $self->{date_containers}= {};
   $self->{date_output}= {};
   $self->{epoch}= 1;
   $self->{root}= [$input,1];
   $self->{current}= [$self->{root},[]];
   my $ok= eval {
      local $JGraft::JSON::Object::EXEC=$self;
      local ($Math::BigRat::accuracy,$Math::BigRat::precision);
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
   if (ref $amount) { $amount=JGraft::Util::to_native_number($amount) }
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
   if ($type==TYPE_DATE) { $self->_date($v); return }
   if (!ref $v || JSON::PP::is_bool($v) || $type==TYPE_NUMBER || $type==TYPE_STRING) {
      $self->_step(length($v)*.001) if $type == TYPE_STRING;
      $self->_check_string($v,$ast?'graft':'input') if $type == TYPE_STRING;
      $type != TYPE_NUMBER || is_finite($v) or $self->_fail('UNSUPPORTED_GRAFT','Non-finite input number');
      if ($type==TYPE_NUMBER && ref $v) {
         $self->_step(length($v->isa('JGraft::JSON::Number')?$v->token:$v->isa('Math::BigFloat')?$v->bsstr:$v->bstr));
      }
      return;
   }
   ref($v) eq 'ARRAY' || ref($v) eq 'HASH' or $self->_fail('UNSUPPORTED_GRAFT','Unsupported data reference '.ref($v));
   my $id=refaddr($v);
   $active->{$id} and $self->_fail($ast?'INVALID_GRAFT':'INVALID_TARGET','Cyclic data');
   local $active->{$id}=1;
   my $n= $type==TYPE_ARRAY? scalar @$v : scalar keys %$v;
   if (!$ast && $self->{undo_state} && !$self->{undo_state}{original_ids}{$id}) {
      $self->_charge('mem',32);
      $self->{undo_state}{original_ids}{$id}=1;
   }
   $self->_step($n);
   $self->_allocation(($type==TYPE_ARRAY?80:128)+($type==TYPE_ARRAY?16:64)*$n) if $alloc;
   if ($type==TYPE_ARRAY) {
      for my $i (0..$#$v) {
         exists $v->[$i] or $self->_fail('UNSUPPORTED_GRAFT','Sparse input arrays are not JSON data');
         $self->_inspect($v->[$i],$depth+1,$active,$ast,$alloc);
         $self->_mark_date_container($v) if $self->_contains_date($v->[$i]);
      }
   }
   else {
      my $tie=tied %$v;
      if ($tie && $tie->isa('JGraft::JSON::Object')) {
         for my $i ($tie->_members) {
            $self->_check_string($tie->{tokens}[$i],$ast?'graft key':'input key');
            $self->_inspect($tie->{tokens}[$i+1],$depth+1,$active,$ast,$alloc);
            $self->_mark_date_container($v) if $self->_contains_date($tie->{tokens}[$i+1]);
         }
         return;
      }
      for my $key (keys %$v) {
         $self->_step(length($key)*.001);
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
   my ($self,$v)= @_;
   return $v if ($self->{owned}{refaddr($v)} || 0) == $self->{epoch};
   if (ref $v eq 'ARRAY') {
      my $copy=$self->_new_array(scalar @$v);
      $self->_step(scalar @$v);
      @$copy=@$v;
      $self->_mark_date_container($copy) if $self->{date_containers}{refaddr($v)};
      JGraft::_Split->_copy_meta($self,$v,$copy,0,scalar @$v) if $self->{split_meta}{refaddr($v)};
      $self->{lineage}{refaddr($copy)}=$self->{lineage}{refaddr($v)} || refaddr($v) if $self->{undo_state};
      return $copy;
   }
   my $tie=tied %$v;
   my $copy;
   if ($tie && $tie->isa('JGraft::JSON::Object')) { $copy=$self->_own($tie->_clone) }
   else {
      $copy=$self->_new_hash(scalar keys %$v);
      $self->_step(scalar keys %$v);
      %$copy=%$v;
   }
   $self->_mark_date_container($copy) if $self->{date_containers}{refaddr($v)};
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
   if (blessed($v) && $v->isa('DateTime')) { $self->_allocation(256); return $v->clone }
   if (blessed($v) && type_mask($v)==TYPE_NUMBER && !$v->isa('JGraft::JSON::Number')) {
      $self->_allocation(128+4*length($v->isa('Math::BigFloat')?$v->bsstr:$v->bstr));
      return $v->copy;
   }
   return $v unless ref $v eq 'ARRAY' || ref $v eq 'HASH';
   if (ref $v eq 'ARRAY') {
      my $out=$self->_new_array(scalar @$v);
      $self->{lineage}{refaddr($out)}=$self->{lineage}{refaddr($v)} || refaddr($v) if $self->{undo_state};
      $self->_step(scalar @$v);
      for my $i (0..$#$v) { $out->[$i]=$self->_clone_tree($v->[$i],$depth+1) }
      $self->_mark_date_container($out) if $self->{date_containers}{refaddr($v)};
      JGraft::_Split->_copy_meta($self,$v,$out,0,scalar @$v) if $self->{split_meta}{refaddr($v)};
      return $out;
   }
   my $tie=tied %$v;
   my $out;
   if ($tie && $tie->isa('JGraft::JSON::Object')) {
      $out=$self->_own($tie->_clone(sub { $self->_clone_tree($_[0],$depth+1) }));
   }
   else {
      $out=$self->_new_hash(scalar keys %$v);
      $self->_step(scalar keys %$v);
      $out->{$_}=$self->_clone_tree($v->{$_},$depth+1) for keys %$v;
   }
   $self->{lineage}{refaddr($out)}=$self->{lineage}{refaddr($v)} || refaddr($v) if $self->{undo_state};
   $self->_mark_date_container($out) if $self->{date_containers}{refaddr($v)};
   return $out;
}

sub _run {
   my ($self,$action,$depth)= @_;
   $self->_depth($depth);
   $self->_step(1);
   is_action($action) or $self->_fail('INVALID_GRAFT','Expected an action object');
   local $self->{action}=$action;
   local $self->{temp}=[$self->_new_hash(0),1];
   return $action->_execute($self,$depth);
}

# Keep action execution methods alongside expression execution methods in this
# module, with per-action context and TEMP lifetime managed by _run above.
sub JGraft::Action::_execute {
   my ($action,$self)= @_;
   $self->_fail('UNSUPPORTED_GRAFT','Action '.$action->_name.' is not implemented');
}
sub JGraft::Action::JGRAFT::_execute {
   my ($action,$self,$depth)= @_;
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
sub JGraft::Action::MATCH::_execute {
   my ($action,$self,$depth)= @_;
   my $match=$self->_match($action->match_spec,$depth+1,1);
   $match or $self->_fail('NO_MATCH','Current node does not match');
   local $self->{cap}=[$match->{captures},1];
   $self->_step(scalar @{$action->actions});
   $self->_run($_,$depth+1) for @{$action->actions};
}
sub JGraft::Action::IF::_execute {
   my ($action,$self,$depth)= @_;
   $self->_step(scalar @{$action->branches});
   for my $branch (@{$action->branches}) {
      my $match=$self->_match($branch->[0],$depth+1,1);
      next unless $match;
      local $self->{cap}=[$match->{captures},1];
      $self->_run($branch->[1],$depth+1);
      return;
   }
   $self->_run($action->else_action,$depth+1) if exists $action->{else_action};
}
sub JGraft::Action::AT::_execute {
   my ($action,$self,$depth)= @_;
   my $loc=$self->_path($action->path,'at',$depth+1);
   my ($v,$canonical)=$self->_read($loc);
   local $self->{current}=$canonical;
   $self->_step(scalar @{$action->actions});
   $self->_run($_,$depth+1) for @{$action->actions};
}
sub JGraft::Action::COPY::_execute {
   my ($action,$self,$depth)= @_;
   my $pairs=$action->assignments;
   $self->_step(scalar @$pairs);
   for my $pair (@$pairs) {
      my ($v,$metadata)=$self->_value_source($pair->[0],$depth+1);
      # Keep the value stable even if destination expressions read from it.
      $self->_snapshot($v);
      my $loc=$self->_path($pair->[1],'write',$depth+1);
      my $dest=$self->_probe($loc,undef,0);
      $self->_write($dest,$v,$metadata);
   }
}
sub JGraft::Action::MOVE::_execute {
   my ($action,$self,$depth)= @_;
   return $self->_move($action->moves,$depth+1);
}
sub JGraft::Action::RAISE::_execute {
   no warnings 'utf8';
   my ($action,$self,$depth)=@_;
   my $message=$self->_eval($action->message,$depth+1);
   type_mask($message)==TYPE_STRING or $self->_fail('INVALID_TARGET','RAISE message must be a string');
   $self->_step(length($message));
   while ($message =~ /(.)/gs) {
      my $cp=ord($1);
      ($cp<32 || ($cp>=127 && $cp<=159) || ($cp>=0xd800 && $cp<=0xdfff)
         || ($cp>=0xfdd0 && $cp<=0xfdef) || ($cp & 0xffff)>=0xfffe)
         and $self->_fail('INVALID_TARGET','RAISE message contains a forbidden character');
   }
   my $level=$action->level;
   $level={info=>0,warn=>1,fail=>2}->{$level} if type_mask($level)==TYPE_STRING;
   my $entry=$self->_new_hash(exists($action->{data})?3:2);
   @$entry{qw(level message)}=($level,$message);
   if (exists $action->{data}) {
      my $data=$self->_export_dates($self->_eval($action->data,$depth+1),$depth+1,{});
      $entry->{data}=$self->_snapshot($data);
   }
   $self->_charge('mem',16+4*length($message));
   push @{$self->{logs}},$entry;
   $self->_fail('NO_MATCH',$message) if $level==2;
}
sub JGraft::Action::SPLICE::_execute {
   my ($action,$self,$depth)=@_;
   my $loc=$self->_path($action->array_elem_path,'write',$depth+1);
   @{$loc->[1]} or $self->_fail('INVALID_TARGET','SPLICE requires an array element path');
   my @parts=@{$loc->[1]};
   my $last=pop @parts;
   my ($array,$parent_loc)=$self->_read([$loc->[0],\@parts,$loc->[2]]);
   type_mask($array)==TYPE_ARRAY or $self->_fail('INVALID_TARGET','SPLICE requires an array element path');
   my $offset=$self->_selector($last,$array,0);
   my $count=$self->_eval($action->count_expr,$depth+1);
   !defined($count) || is_integer($count) or $self->_fail('INVALID_OPERAND','SPLICE count must be an integer or null');
   my $size=@$array;
   $count=$size-$offset unless defined $count;
   $count+=$size-$offset if $count<0;
   $count>=0 && $count<=$size-$offset or $self->_fail('INVALID_TARGET','SPLICE count is out of range');
   my (@values,@sources);
   $self->_step(scalar @{$action->replacements});
   $self->_charge('mem',32*@{$action->replacements});
   for my $arg (@{$action->replacements}) {
      my ($value,$source)=$self->_value_source($arg,$depth+1);
      $value=$self->_export_dates($value,$depth+1,{})
         if ($loc->[2] || '') eq 'node' || refaddr($loc->[0])==refaddr($self->{root});
      push @values,$self->_snapshot($value);
      push @sources,$source;
   }
   return unless $count || @values;
   # Reserve array shifting and metadata repair before touching the tree.
   $self->_step($size+@values);
   $self->_charge('mem',16*($size+@values));
   $self->{undo_state}->_record($self,$parent_loc) if $self->{undo_state};
   my $dest=[$parent_loc->[0],[@{$parent_loc->[1]},$offset],$loc->[2]];
   ($array)=$self->_parent($dest);
   require JGraft::_Split;
   my $meta=JGraft::_Split->_splice_meta($self,$array,$offset,$count,\@sources);
   splice @$array,$offset,$count,@values;
   if ($meta) {
      $self->{split_meta}{refaddr($array)}=$meta;
      JGraft::_Split->_fill_meta($self,$array,1);
   }
   else { delete $self->{split_meta}{refaddr($array)} }
   for my $value (@values) {
      next unless $self->_contains_date($value);
      # Mark ancestors too: the array may be inside a TEMP/STASH container.
      my $container=$parent_loc->[0][0];
      $self->_step(1+@{$parent_loc->[1]});
      $self->_mark_date_container($container);
      for my $part (@{$parent_loc->[1]}) {
         $container=$self->_child($container,$part);
         $self->_mark_date_container($container);
      }
      last;
   }
}
sub JGraft::Action::ATSPLIT::_execute {
   my ($action,$self,$depth)=@_;
   require JGraft::_Split;
   my ($text,$target)=$self->_read($self->_path($action->path,'at',$depth+1));
   my ($config,$result);
   {
      local $self->{current}=$target;
      $config=JGraft::_Split->_config($self,$action->split_spec,$depth+1,'both');
      my $array=JGraft::_Split->_split($self,$config,$text,$depth+1);
      local $self->{current}=[[$array,1],[]];
      local $self->{match_cursor};
      $self->_step(scalar @{$action->actions});
      $self->_run($_,$depth+1) for @{$action->actions};
      $result=JGraft::_Split->_join($self,$config,($self->_read($self->{current}))[0],$depth+1);
   }
   $self->_write($target,$result);
}

sub _path {
   my ($self,$expr,$mode,$depth)= @_;
   $self->_depth($depth);
   $self->_step(1);
   is_expr($expr) or $self->_fail('INVALID_OPERAND','Path must be a reference expression');
   local $self->{expression}=$expr;
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
      next if $t==TYPE_STRING || ($t==TYPE_BOOLEAN && !$v);
      if ($t==TYPE_NUMBER && is_finite($v)) {
         next if is_integer($v) || ($mode eq 'move_dst' && $i==$#parts && $v*2==int($v*2));
      }
      $self->_fail($literal[$i]?'INVALID_GRAFT':'INVALID_OPERAND','Invalid path selector');
   }
   $ns eq 'temp' && !@parts and $self->_fail(
      (grep is_expr($_), @{$expr->path})?'INVALID_OPERAND':'INVALID_GRAFT','TEMP root is inaccessible');
   if ($ns ne 'node' && ($mode eq 'write' || $mode =~ /^move_/) && !@parts) {
      $self->_fail((grep is_expr($_), @{$expr->path})?'INVALID_OPERAND':'INVALID_GRAFT','Namespace root cannot be overwritten or moved');
   }
   if ($ns ne 'node' && @parts && type_mask($parts[0])==TYPE_NUMBER) {
      is_integer($parts[0]) or $self->_fail($literal[0]?'INVALID_GRAFT':'INVALID_OPERAND',
         'Namespace property must be an integer or string');
      my $key=$parts[0];
      $parts[0]="$key";
   }
   $self->_charge('mem',32+16*(@parts+@{$base->[1]}));
   return [$base->[0],[@{$base->[1]},@parts],$ns];
}

sub _selector {
   my ($self,$value,$container,$half)= @_;
   my $type=type_mask($value);
   my $kind=type_mask($container);
   if ($kind==TYPE_DATE) {
      $type==TYPE_STRING or $self->_fail('INVALID_TARGET','Date selectors must be field names');
      return $value;
   }
   if ($kind==TYPE_OBJECT) {
      $type==TYPE_STRING or $self->_fail('INVALID_TARGET','Object selectors must be strings');
      return $value;
   }
   $kind==TYPE_ARRAY or $self->_fail('INVALID_TARGET','Path descends through a scalar');
   my $len=@$container;
   return $len if $type==TYPE_BOOLEAN && !$value;
   $type==TYPE_NUMBER && is_finite($value) or $self->_fail('INVALID_TARGET','Array selectors must be numbers');
   $value=$self->_number($value) if ref $value;
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
   my $record=$self->{pending}{refaddr($v)};
   return !$record || !$record->{deleted}{0+$key};
}
sub _child {
   if (type_mask($_[1])==TYPE_DATE) {
      my $date=$_[0]->_date($_[1]);
      if ($_[2] eq 'second') {
         my $n=length($date->fraction);
         $_[0]->_step($n*.01+1); $_[0]->_charge('mem',2*$n);
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
   return ($v,[$cell,\@canonical,$loc->[2]]);
}
sub _same_key {
   my ($self,$a,$b)= @_;
   return 0 unless type_mask($a)==type_mask($b);
   $self->_step(1+(length($a)+length($b))*.001) if type_mask($a)==TYPE_STRING;
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
         $v=$kind==TYPE_STRING? {} : [];
      }
      type_mask($v)!=TYPE_DATE or $self->_fail('INVALID_TARGET','Date fields are immutable');
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
   return [$cell,\@canonical,$loc->[2]];
}

sub _parent {
   my ($self,$loc)= @_;
   my ($cell,$parts)=@$loc;
   if (!$cell->[1]) {
      $cell->[0]=type_mask($parts->[0])==TYPE_STRING? $self->_new_hash(0):$self->_new_array(0);
      $cell->[1]=1;
   }
   type_mask($cell->[0])!=TYPE_DATE or $self->_fail('INVALID_TARGET','Date fields are immutable');
   my $v=$self->_cow($cell->[0]);
   $cell->[0]=$v;
   for my $i (0..$#$parts-1) {
      my $key=$parts->[$i];
      my $child;
      if ($self->_present($v,$key)) { $child=$self->_child($v,$key) }
      else { $child=type_mask($parts->[$i+1])==TYPE_STRING? $self->_new_hash(0):$self->_new_array(0) }
      type_mask($child)!=TYPE_DATE or $self->_fail('INVALID_TARGET','Date fields are immutable');
      $child=$self->_cow($child);
      $self->_put($v,$key,$child);
      $v=$child;
   }
   return ($v,$parts->[-1]);
}
sub _put {
   my ($self,$parent,$key,$value,$source)= @_;
   if (ref $parent eq 'HASH') {
      $self->_charge('mem',64+length($key)) unless exists $parent->{$key};
      $parent->{$key}=$value;
   }
   else {
      my $rec=$self->{pending}{refaddr($parent)};
      my $inserting=$key==@$parent || ($rec && $rec->{deleted}{0+$key});
      my $existing_meta=$self->{split_meta}{refaddr($parent)};
      my $metadata=$inserting && ($source || $existing_meta);
      $rec=$self->_pending($parent) if $metadata && $self->{moving};
      if ($key==@$parent) {
         $self->_charge('mem',16);
         if ($rec) {
            $self->_step($rec->{metadata} || $metadata?4:2);
            $self->_charge('mem',$rec->{metadata} || $metadata?112:16);
         }
      }
      if ($metadata) {
         $self->_charge('mem',96);
         $self->_step($existing_meta?2:2*(@$parent+1)) unless $self->{moving};
         my $row=JGraft::_Split->_insert_meta($self,$parent,$source);
         if (!$row && !$self->{moving} && $existing_meta) {
            my $previous=$key? $existing_meta->{rows}[$key-1] : undef;
            $row=[$previous? $previous->[0] : '',$previous? $previous->[1] : '',''];
         }
         $self->{split_meta}{refaddr($parent)}{rows}[$key]=$row;
      }
      delete $rec->{deleted}{0+$key} if $rec;
      $parent->[$key]=$value;
      JGraft::_Split->_fill_meta($self,$parent,1) if $metadata && !$self->{moving} && !$existing_meta;
   }
   $self->_mark_date_container($parent) if $self->_contains_date($value);
}
sub _write {
   my ($self,$loc,$value,$source)= @_;
   $self->_step(1+@{$loc->[1]});
   if (($loc->[2] || '') eq 'node' || refaddr($loc->[0])==refaddr($self->{root})) {
      $value=$self->_export_dates($value,1,{});
   }
   $self->{undo_state}->_record($self,$loc) if $self->{undo_state};
   unless (@{$loc->[1]}) { @{$loc->[0]}=($value,1); return }
   my ($parent,$key)=$self->_parent($loc);
   if (ref $parent eq 'ARRAY' && !is_integer($key)) {
      my $rec=$self->_pending($parent);
      $self->_step(4);
      $self->_charge('mem',168);
      my $row;
      $row=JGraft::_Split->_insert_meta($self,$parent,$source) if $source || $self->{split_meta}{refaddr($parent)};
      push @{$rec->{insert}{0+$key}},$value;
      push @{$rec->{insert_meta}{0+$key}},$row;
   }
   else { $self->_put($parent,$key,$value,$source) }
   if ($self->_contains_date($value)) {
      my $container=$loc->[0][0];
      $self->_step(scalar @{$loc->[1]});
      for my $part (@{$loc->[1]}) {
         last unless ref($container) eq 'ARRAY' || ref($container) eq 'HASH';
         $self->_mark_date_container($container);
         last unless $self->_present($container,$part);
         $container=$self->_child($container,$part);
      }
   }
}
sub _pending {
   my ($self,$array)= @_;
   my $id=refaddr($array);
   return $self->{pending}{$id} if $self->{pending}{$id};
   # Reserve the final compaction's work and scratch space before editing.
   my $metadata=$self->{split_meta}{$id}?1:0;
   $self->_step(($metadata?4:2)*@$array+1);
   $self->_charge('mem',192+($metadata?112:16)*@$array);
   return $self->{pending}{$id}={array=>$array,deleted=>{},insert=>{},insert_meta=>{},metadata=>$metadata};
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
      my (@out,@rows);
      my $meta=$self->{split_meta}{refaddr($array)};
      for my $i (0..$#$array) {
         push @out,@{$rec->{insert}{$i-.5} || []};
         push @rows,@{$rec->{insert_meta}{$i-.5} || []} if $meta;
         push @out,$array->[$i] unless $rec->{deleted}{0+$i};
         push @rows,$meta->{rows}[$i] if $meta && !$rec->{deleted}{0+$i};
      }
      push @out,@{$rec->{insert}{@$array-.5} || []};
      push @rows,@{$rec->{insert_meta}{@$array-.5} || []} if $meta;
      @$array=@out;
      if ($meta) { $meta->{rows}=\@rows; JGraft::_Split->_fill_meta($self,$array,1) }
   }
   $self->{pending}={};
}
sub _move {
   my ($self,$pairs,$depth)= @_;
   local $self->{moving}=1;
   $self->_step(scalar @$pairs);
   my $ok=eval {
      for my $pair (@$pairs) {
         my $src=defined $pair->[0]? $self->_path($pair->[0],'move_src',$depth+1):undef;
         my $dst=defined $pair->[1]? $self->_path($pair->[1],'move_dst',$depth+1):undef;
         my ($value,$canonical)= $src? $self->_read($src) : (undef,undef);
         my $metadata=$canonical && keys %{$self->{split_meta}}? JGraft::_Split->_source($self,$canonical) : undef;
         my $dest=$dst? $self->_probe($dst,$canonical,1) : undef;
         if ($canonical && $dest && refaddr($canonical->[0])==refaddr($dest->[0])
            && @{$canonical->[1]}==@{$dest->[1]}) {
            my $same=1;
            $self->_step(scalar @{$dest->[1]});
            for my $i (0..$#{$dest->[1]}) { $same=0 unless $self->_same_key($canonical->[1][$i],$dest->[1][$i]) }
            next if $same;
         }
         $self->_delete($canonical) if $canonical;
         $self->_write($dest,$value,$metadata) if $dest;
      }
      $self->{current}[0][1] or $self->_fail('INVALID_TARGET','MOVE did not replace the current node');
      $self->_read($self->{current});
      1;
   };
   my $err=$@;
   $self->_finish_moves;
   die $err unless $ok;
}

sub _match {
   my ($self,$spec,$depth,$observable)=@_;
   require JGraft::_Match;
   my $state=JGraft::_Match->_new($self,$observable);
   my ($cell,$parts)=@{$self->{current}};
   my ($value,$exists)=@$cell;
   my $parent;
   $self->_step(scalar @$parts);
   for my $key (@$parts) {
      unless ($exists && (ref($value) eq 'ARRAY' || ref($value) eq 'HASH' || type_mask($value)==TYPE_DATE) && $self->_present($value,$key)) {
         $exists=0; $value=undef; last;
      }
      $parent=$value;
      $value=$self->_child($value,$key);
   }
   my $prop=@$parts? $parts->[-1] : $self->{match_cursor}? $self->{match_cursor}{prop} : undef;
   my $cursor=$state->_cursor($value,$exists,$prop,undef);
   $cursor->{array}=$parent if ref($parent) eq 'ARRAY';
   $cursor->{array}=$self->{match_cursor}{array} if !@$parts && $self->{match_cursor} && $self->{match_cursor}{array};
   $cursor->{string}=$self->{match_cursor}{string} if !@$parts && $self->{match_cursor} && $self->{match_cursor}{string};
   return $state->_test($spec,$cursor,$depth,0)? $state : undef;
}

sub _macro {
   my ($self,$expr,$depth)= @_;
   my $name=$self->_eval($expr->name,$depth+1);
   my $t=type_mask($name);
   $t==TYPE_STRING || ($t==TYPE_NUMBER && is_integer($name)) or $self->_fail('INVALID_OPERAND','Invalid EXPR name');
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
      my $result=$self->_expression($v,$depth);
      $self->_check_string($result,'expression') if type_mask($result)==TYPE_STRING;
      return $result;
   }
   my $t=type_mask($v);
   return $self->_date($v) if $t==TYPE_DATE;
   if ($t==TYPE_ARRAY) {
      my $out=$self->_new_array(scalar @$v);
      $self->_step(scalar @$v);
      for my $i (0..$#$v) {
         my ($value,$metadata)=$self->_value_source($v->[$i],$depth+1);
         $self->_put($out,$i,$value,$metadata);
      }
      return $out;
   }
   if ($t==TYPE_OBJECT) {
      my $tie=tied %$v;
      if ($tie && $tie->isa('JGraft::JSON::Object')) {
         my $out=$self->_own($tie->_clone(sub { $self->_eval($_[0],$depth+1) }));
         $self->_mark_date_container($out) if $self->{date_containers}{refaddr($v)};
         return $out;
      }
      my $out=$self->_new_hash(scalar keys %$v);
      $self->_step(scalar keys %$v);
      for my $key (keys %$v) {
         $self->_check_string($key,'expression key');
         $out->{$key}=$self->_eval($v->{$key},$depth+1);
         $self->_mark_date_container($out) if $self->_contains_date($out->{$key});
      }
      return $out;
   }
   $self->_step(length($v)*.001) if $t==TYPE_STRING;
   $self->_check_string($v,'literal') if $t==TYPE_STRING;
   $t==TYPE_NULL || $t==TYPE_BOOLEAN || $t==TYPE_NUMBER || $t==TYPE_STRING or $self->_fail('UNSUPPORTED_GRAFT','Unsupported literal value');
   return $v;
}
sub _value_source {
   my ($self,$value,$depth)=@_;
   $self->_depth($depth); $self->_step(1);
   if (is_expr($value)) {
      local $self->{expression}=$value;
      return $self->_value_source($self->_macro($value,$depth+1),$depth+1) if $value->_name eq 'EXPR';
      if ($value->is_ref && exists $value->{path}) {
         my ($result,$loc)=$self->_read($self->_path($value,'read',$depth+1));
         return ($result,keys %{$self->{split_meta}}? JGraft::_Split->_source($self,$loc):undef);
      }
   }
   return ($self->_eval($value,$depth+1),undef);
}
sub _input_value {
   my ($self,$expr,$field,$depth)= @_;
   return $self->_eval($expr->{$field},$depth+1) if exists $expr->{$field};
   return ($self->_read($self->{current}))[0];
}
sub _date {
   my ($self,$value)=@_;
   require JGraft::Date;
   return $value if blessed($value) && $value->isa('JGraft::Date');
   my $id=ref($value)?refaddr($value):undef;
   return $self->{dates}{$id}[1] if defined($id) && $self->{dates}{$id};
   my $size=ref($value) eq 'HASH'? scalar keys %$value : 0;
   $self->_step(16+$size+(type_mask($value)==TYPE_STRING?length($value)*.01:0));
   $self->_allocation(256+128*$size+(type_mask($value)==TYPE_STRING?8*length($value):0));
   my $date=eval { JGraft::Date->new($value) };
   unless ($date) {
      my $error=$@;
      die $error if ref $error;
      $self->_fail($error =~ /UNSUPPORTED_GRAFT:/?'UNSUPPORTED_GRAFT':'INVALID_TARGET',"Invalid date: $error");
   }
   $self->{dates}{$id}=[$value,$date] if defined $id;
   return $date;
}
sub _contains_date {
   my ($self,$value)=@_;
   return 0 unless ref $value;
   return type_mask($value)==TYPE_DATE || $self->{date_containers}{refaddr($value)};
}
sub _mark_date_container {
   my ($self,$value)=@_;
   my $id=refaddr($value);
   return if $self->{date_containers}{$id};
   $self->_charge('mem',64);
   $self->{date_containers}{$id}=$value;
   weaken($self->{date_containers}{$id});
}
sub _export_dates {
   my ($self,$value,$depth,$memo)=@_;
   return $value unless $self->_contains_date($value);
   $self->_depth($depth); $self->_step(1);
   my $id=refaddr($value);
   if (type_mask($value)==TYPE_DATE) {
      return $self->{date_output}{$id}[1] if exists $self->{date_output}{$id};
      my $date=$self->_date($value);
      my $canonical=refaddr($date);
      return $self->{date_output}{$canonical}[1] if exists $self->{date_output}{$canonical};
      $self->_allocation(256+length($date->fraction));
      my $format=$self->{options}{date_format} || 'iso8601';
      my $out;
      if (ref($format) eq 'CODE') { $out=$format->($date) }
      else {
         my $ok=eval { $out=$date->format($format); 1 };
         $self->_fail('UNSUPPORTED_GRAFT',"Cannot export date: $@") unless $ok;
      }
      if (type_mask($out)==TYPE_STRING) {
         $self->_step(length($out)*.001); $self->_charge('mem',4*length($out));
         $self->_check_string($out,'date output');
      }
      $self->{date_output}{$canonical}=[$date,$out];
      $self->{date_output}{$id}=[$value,$out];
      $self->{date_output}{refaddr($out)}=[$out,$out] if type_mask($out)==TYPE_DATE;
      return $out;
   }
   return $memo->{$id} if exists $memo->{$id};
   my $out=ref($value) eq 'ARRAY'? $self->_new_array(scalar @$value) : $self->_new_hash(scalar keys %$value);
   $memo->{$id}=$out;
   if (ref($value) eq 'ARRAY') {
      $self->_step(scalar @$value);
      for my $i (0..$#$value) {
         $self->_present($value,$i) or $self->_fail('INVALID_TARGET','Cannot export a deleted array element');
         $self->_put($out,$i,$self->_export_dates($value->[$i],$depth+1,$memo));
      }
      JGraft::_Split->_copy_meta($self,$value,$out,0,scalar @$value) if $self->{split_meta}{$id};
   }
   else {
      my $tie=tied %$value;
      if ($tie && $tie->isa('JGraft::JSON::Object')) {
         $out=$self->_own($tie->_clone(sub { $self->_export_dates($_[0],$depth+1,$memo) }));
         $memo->{$id}=$out;
         return $out;
      }
      $self->_step(scalar keys %$value);
      for my $key (keys %$value) { $self->_put($out,$key,$self->_export_dates($value->{$key},$depth+1,$memo)) }
   }
   return $out;
}
sub _expression {
   my ($self,$expr,$depth)= @_;
   return $expr->_execute($self,$depth);
}

# Install execution methods here so parsing-only users need not load them.
# References and match expressions inherit their category's common handler.
sub JGraft::Expr::_execute {
   my ($expr,$self)= @_;
   $self->_fail('UNSUPPORTED_GRAFT','Expression '.$expr->_name.' is not implemented');
}
sub JGraft::Expr::Ref::_execute {
   my ($expr,$self,$depth)= @_;
   return ($self->_read($self->_path($expr,'read',$depth+1)))[0];
}
sub JGraft::Expr::EXPR::_execute {
   my ($expr,$self,$depth)= @_;
   return $self->_eval($self->_macro($expr,$depth+1),$depth+1);
}
sub JGraft::Expr::Match::_execute {
   my ($expr,$self,$depth)= @_;
   return $self->_match($expr,$depth+1)? JSON::PP::true : JSON::PP::false;
}
sub JGraft::Expr::CAPTURE::_execute {
   my ($expr,$self,$depth)= @_;
   my $match=$self->_match($expr->match_expr,$depth+1,1);
   return $match? $match->{captures} : JSON::PP::false;
}
sub JGraft::Expr::CURPROP::_execute {
   my ($expr,$self)= @_;
   return $self->{match_cursor}{prop} if $self->{match_cursor};
   return @{$self->{current}[1]}? $self->{current}[1][-1] : undef;
}
sub JGraft::Expr::FAIL::_execute {
   my ($expr,$self)= @_;
   $self->_fail('INVALID_TARGET','FAIL expression');
}
sub JGraft::Expr::LENGTH::_execute {
   my ($expr,$self,$depth)= @_;
   my $v=$self->_input_value($expr,'value_expr',$depth);
   my $t=type_mask($v);
   return scalar @$v if $t==TYPE_ARRAY;
   if ($t==TYPE_STRING) { $self->_step(length($v)*.001); return length($v) }
   $self->_fail('INVALID_TARGET','LENGTH expects an array or string');
}
sub JGraft::Expr::SLICE::_execute {
   my ($expr,$self,$depth)= @_;
   return $self->_slice($expr,$depth+1);
}
sub JGraft::Expr::SPLIT::_execute {
   my ($expr,$self,$depth)=@_;
   require JGraft::_Split;
   my $config=JGraft::_Split->_config($self,$expr->split_spec,$depth+1,'split');
   return JGraft::_Split->_split($self,$config,$self->_input_value($expr,'string_expr',$depth),$depth+1);
}
sub JGraft::Expr::JOIN::_execute {
   my ($expr,$self,$depth)=@_;
   require JGraft::_Split;
   my $config=JGraft::_Split->_config($self,$expr->split_spec,$depth+1,'join');
   return JGraft::_Split->_join($self,$config,$self->_input_value($expr,'array_expr',$depth),$depth+1);
}
sub JGraft::Expr::LOCAL::_execute {
   my ($expr,$self,$depth)= @_;
   my $copy=$self->_new_hash(scalar keys %{$self->{temp}[0]});
   $self->_step(scalar keys %{$self->{temp}[0]});
   %$copy=%{$self->{temp}[0]};
   local $self->{temp}=[$copy,1];
   local $self->{current}=$self->{current};
   local $self->{match_cursor}=$self->{match_cursor};
   $self->_step(scalar @{$expr->bindings});
   for my $pair (@{$expr->bindings}) {
      my $key=$self->_eval($pair->[0],$depth+1);
      my $t=type_mask($key);
      $t==TYPE_NULL || $t==TYPE_STRING || ($t==TYPE_NUMBER && is_finite($key)) or $self->_fail('INVALID_OPERAND','Invalid LOCAL property');
      my $value=$self->_eval($pair->[1],$depth+1);
      if (!defined $key) { $self->{current}=[[$value,1],[]]; $self->{match_cursor}=undef }
      else { $self->{temp}[0]{"$key"}=$value }
   }
   return $self->_eval($expr->return_value_expr,$depth+1);
}

sub JGraft::Expr::CONCAT::_execute {
   my ($expr,$self,$depth)=@_;
   my ($type,$size,@values);
   $size=0;
   $self->_step(scalar @{$expr->value_exprs});
   $self->_charge('mem',16*@{$expr->value_exprs});
   for my $arg (@{$expr->value_exprs}) {
      my $value=$self->_eval($arg,$depth+1);
      my $t=type_mask($value);
      ($t==TYPE_STRING || $t==TYPE_ARRAY) && (!defined($type) || $type==$t)
         or $self->_fail('INVALID_TARGET','CONCAT expects homogeneous arrays or strings');
      $type=$t;
      $size+=$t==TYPE_ARRAY? scalar @$value : length($value);
      push @values,$value;
   }
   if ($type==TYPE_STRING) {
      $self->_step($size*.001); $self->_charge('mem',4*$size);
      return join('',@values);
   }
   my $out=$self->_new_array($size);
   $self->_step($size);
   for my $array (@values) {
      my $offset=@$out;
      for my $i (0..$#$array) {
         $self->_present($array,$i) or $self->_fail('INVALID_TARGET','CONCAT encounters a deleted element');
         push @$out,$array->[$i];
      }
      JGraft::_Split->_append_meta($self,$array,$out,$offset) if $self->{split_meta}{refaddr($array)};
      $self->_mark_date_container($out) if $self->{date_containers}{refaddr($array)};
   }
   if ($self->{split_meta}{refaddr($out)}) {
      $self->_charge('mem',96*$size);
      JGraft::_Split->_fill_meta($self,$out);
   }
   return $out;
}

# Each callback sees the original element and its original index. Localizing
# both fields also isolates callbacks from an enclosing match cursor.
sub _iterate_array {
   my ($self,$expr,$depth,$mode)=@_;
   my $acc=$self->_eval($expr->initial_value,$depth+1) if $mode eq 'reduce';
   my $array=$self->_input_value($expr,'array_expr',$depth);
   type_mask($array)==TYPE_ARRAY or $self->_fail('INVALID_TARGET','Array iteration expects an array');
   $self->_step(scalar @$array);
   $self->_charge('mem',80*@$array);
   my $out=$self->_new_array(scalar @$array) unless $mode eq 'reduce';
   my $meta=$self->{split_meta}{refaddr($array)};
   my @selected;
   $self->_charge('mem',16*@$array) if $meta && $mode eq 'filter';
   if ($mode eq 'map') {
      @$out=(undef)x scalar @$array;
      JGraft::_Split->_copy_meta($self,$array,$out,0,scalar @$array) if $meta;
   }
   local $self->{temp}=$self->{temp};
   if ($mode eq 'reduce') {
      my $temp=$self->_new_hash(scalar keys %{$self->{temp}[0]});
      $self->_step(scalar keys %{$self->{temp}[0]});
      %$temp=%{$self->{temp}[0]};
      $self->{temp}=[$temp,1];
   }
   local $self->{current}=$self->{current};
   local $self->{match_cursor};
   for my $i (0..$#$array) {
      $self->_present($array,$i) or $self->_fail('INVALID_TARGET','Array iteration encounters a deleted element');
      $self->{current}=[[$array,1],[$i]];
      if ($mode eq 'reduce') {
         $self->_put($self->{temp}[0],$expr->temp_prop,$acc);
         $acc=$self->_eval($expr->reduce_expr,$depth+1);
      }
      elsif ($mode eq 'filter') {
         if ($self->_match($expr->match_expr,$depth+1)) {
            push @$out,$array->[$i];
            push @selected,$i if $meta;
         }
      }
      else { $self->_put($out,$i,$self->_eval($expr->transform_expr,$depth+1)) }
   }
   return $acc if $mode eq 'reduce';
   JGraft::_Split->_select_meta($self,$array,$out,\@selected) if $mode eq 'filter' && $meta;
   $self->_mark_date_container($out) if $mode eq 'filter' && @$out && $self->{date_containers}{refaddr($array)};
   return $out;
}
sub JGraft::Expr::REDUCE::_execute { $_[1]->_iterate_array($_[0],$_[2],'reduce') }
sub JGraft::Expr::FILTER::_execute { $_[1]->_iterate_array($_[0],$_[2],'filter') }
sub JGraft::Expr::MAP::_execute { $_[1]->_iterate_array($_[0],$_[2],'map') }

sub JGraft::Expr::PROPS::_execute {
   my ($expr,$self,$depth)=@_;
   my $object=$self->_input_value($expr,'object_expr',$depth);
   type_mask($object)==TYPE_OBJECT or $self->_fail('INVALID_TARGET','PROPS expects an object');
   my $n=keys %$object;
   my $levels=1; $levels++ while 2**$levels<$n;
   $self->_step($n*$levels);
   $self->_charge('mem',16*$n);
   my @keys=sort { $self->_compare_values($a,$b,$depth+1) } keys %$object;
   my $options=$expr->{options} || 0;
   my $out=$self->_new_array($options==2?2:$n);
   my ($names,$values);
   if ($options==2) { $names=$self->_new_array($n); $values=$self->_new_array($n); @$out=($names,$values) }
   for my $key (@keys) {
      $self->_check_string($key,'expression key');
      if (!$options) { push @$out,$key }
      elsif ($options==1) {
         my $pair=$self->_new_array(2);
         $self->_put($pair,0,$key); $self->_put($pair,1,$object->{$key});
         $self->_put($out,scalar @$out,$pair);
      }
      else { push @$names,$key; $self->_put($values,scalar @$values,$object->{$key}) }
   }
   $self->_mark_date_container($out) if $options==2 && $self->_contains_date($values);
   return $out;
}
sub JGraft::Expr::MKOBJ::_execute {
   my ($expr,$self,$depth)=@_;
   my @pairs;
   if (exists $expr->{prop_array_expr}) {
      my $pairs=$self->_eval($expr->prop_array_expr,$depth+1);
      type_mask($pairs)==TYPE_ARRAY or $self->_fail('INVALID_TARGET','MKOBJ expects property pairs');
      $self->_step(scalar @$pairs); $self->_charge('mem',16*@$pairs);
      for my $i (0..$#$pairs) {
         $self->_present($pairs,$i) or $self->_fail('INVALID_TARGET','Deleted MKOBJ pair');
         my $pair=$pairs->[$i];
         type_mask($pair)==TYPE_ARRAY && @$pair==2 && $self->_present($pair,0) && $self->_present($pair,1)
            or $self->_fail('INVALID_TARGET','MKOBJ expects two-element pairs');
         push @pairs,$pair;
      }
   }
   else {
      my @args;
      $self->_step(scalar @{$expr->value_exprs});
      $self->_charge('mem',32*@{$expr->value_exprs});
      push @args,$self->_eval($_,$depth+1) for @{$expr->value_exprs};
      @args && @args%2==0 or $self->_fail('INVALID_TARGET','MKOBJ expects property pairs');
      if (@args==2 && type_mask($args[0])==TYPE_ARRAY && type_mask($args[1])==TYPE_ARRAY) {
         my ($names,$values)=@args;
         @$names==@$values or $self->_fail('INVALID_TARGET','MKOBJ array lengths differ');
         $self->_step(scalar @$names); $self->_charge('mem',48*@$names);
         for my $i (0..$#$names) {
            $self->_present($names,$i) && $self->_present($values,$i) or $self->_fail('INVALID_TARGET','Deleted MKOBJ element');
            push @pairs,[$names->[$i],$values->[$i]];
         }
      }
      else { for (my $i=0;$i<@args;$i+=2) { push @pairs,[@args[$i,$i+1]] } }
   }
   my $out=$self->_new_hash(scalar @pairs);
   $self->_step(scalar @pairs);
   for my $pair (@pairs) {
      my ($key,$value)=@$pair;
      type_mask($key)==TYPE_STRING or $self->_fail('INVALID_TARGET','MKOBJ names must be strings');
      $self->_check_string($key,'expression key');
      $self->_step(length($key)*.001);
      exists $out->{$key} and $self->_fail('INVALID_TARGET','Duplicate MKOBJ property');
      $self->_put($out,$key,$value);
   }
   return $out;
}
sub JGraft::Expr::CASE::_execute {
   my ($expr,$self,$depth)=@_;
   $self->_step(scalar @{$expr->branches});
   for my $pair (@{$expr->branches}) {
      return $self->_eval($pair->[1],$depth+1) if $self->_match($pair->[0],$depth+1);
   }
   return $self->_eval($expr->else_value_expr,$depth+1) if exists $expr->{else_value_expr};
   $self->_fail('INVALID_TARGET','CASE has no matching branch');
}

sub _boolean_value {
   my ($self,$arg,$depth)= @_;
   my $value=$self->_eval($arg,$depth);
   type_mask($value)==TYPE_BOOLEAN or $self->_fail('INVALID_TARGET','Logical operands must be booleans');
   return $value;
}
sub JGraft::Expr::AND::_execute {
   my ($expr,$self,$depth)= @_;
   $self->_step(scalar @{$expr->value_exprs});
   for my $arg (@{$expr->value_exprs}) {
      return JSON::PP::false unless $self->_boolean_value($arg,$depth+1);
   }
   return JSON::PP::true;
}
sub JGraft::Expr::OR::_execute {
   my ($expr,$self,$depth)= @_;
   $self->_step(scalar @{$expr->value_exprs});
   for my $arg (@{$expr->value_exprs}) {
      return JSON::PP::true if $self->_boolean_value($arg,$depth+1);
   }
   return JSON::PP::false;
}
sub JGraft::Expr::NOT::_execute {
   my ($expr,$self,$depth)= @_;
   $self->_step(scalar @{$expr->value_exprs});
   for my $arg (@{$expr->value_exprs}) {
      return JSON::PP::false if $self->_boolean_value($arg,$depth+1);
   }
   return JSON::PP::true;
}
sub JGraft::Expr::CASTBOOL::_execute {
   my ($expr,$self,$depth)= @_;
   my $v=$self->_input_value($expr,'value_expr',$depth);
   my $t=type_mask($v);
   return $v if $t==TYPE_BOOLEAN;
   return $v? JSON::PP::true : JSON::PP::false if $t==TYPE_NUMBER && ($v==0 || $v==1);
   return $v eq 'true'? JSON::PP::true : JSON::PP::false if $t==TYPE_STRING && ($v eq 'true' || $v eq 'false');
   $self->_fail('INVALID_TARGET','Invalid CASTBOOL input');
}
sub JGraft::Expr::CASTNUM::_execute {
   my ($expr,$self,$depth)= @_;
   my $v=$self->_input_value($expr,'value_expr',$depth);
   my $t=type_mask($v);
   return $v if $t==TYPE_NUMBER;
   if ($t==TYPE_STRING && $v =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/) {
      $self->_step(length($v)*.001);
      my $num=0+$v;
      is_finite($num) or $self->_fail('UNSUPPORTED_GRAFT','Number outside supported range');
      if ($num==0) {
         my ($mantissa)=split /[eE]/,$v,2;
         $mantissa !~ /[1-9]/ or $self->_fail('UNSUPPORTED_GRAFT','Number underflows supported range');
      }
      return $num;
   }
   $self->_fail('INVALID_TARGET','Invalid CASTNUM input');
}
sub JGraft::Expr::CASTSTR::_execute {
   my ($expr,$self,$depth)= @_;
   my $v=$self->_input_value($expr,'value_expr',$depth);
   my $t=type_mask($v);
   return $v if $t==TYPE_STRING;
   return $v? 'true':'false' if $t==TYPE_BOOLEAN;
   if ($t==TYPE_DATE) {
      my $date=$self->_date($v);
      $self->_step(length($date->fraction)*.01+1);
      my $out=$date->to_iso8601;
      $self->_charge('mem',length($out));
      return $out;
   }
   if ($t==TYPE_NUMBER) {
      my $integer=is_integer($v);
      my $out;
      if (ref $v) {
         my $number=$self->_number($v);
         $out=eval { JGraft::Util::to_decimal_string($number) };
         $@ and $self->_fail('UNSUPPORTED_GRAFT',"$@");
      }
      else {
         # Support negative zero via sprintf
         $out= $v? "$v" : sprintf('%g', $v);
      }
      # If scientific notation was used for an integer, expand the digits.
      if ($integer && $out =~ /\A(-?)([0-9]+)(?:\.([0-9]+))?[eE]([+-]?[0-9]+)\z/) {
         my ($sign,$whole,$fraction,$exponent)=($1,$2,defined($3)?$3:'',0+$4);
         my $length=length($sign)+length($whole)+$exponent;
         $self->_step($length*.001); $self->_charge('mem',$length);
         my $digits=$whole.$fraction;
         my $zeros=$exponent-length($fraction);
         $out=$sign.($zeros>=0? $digits.('0'x$zeros) : substr($digits,0,length($digits)+$zeros));
      }
      else { $self->_step(length($out)*.001); $self->_charge('mem',length($out)) }
      return $out;
   }
   $self->_fail('INVALID_TARGET','Invalid CASTSTR input');
}
sub JGraft::Expr::CASTDATE::_execute {
   my ($expr,$self,$depth)=@_;
   return $self->_date($self->_input_value($expr,'value_expr',$depth));
}
sub _compare_values {
   my ($self,$a,$b,$depth)=@_;
   $self->_depth($depth); $self->_step(1);
   my $type=type_mask($a);
   $type==type_mask($b) or $self->_fail('INVALID_TARGET','Comparison requires matching types');
   if ($type==TYPE_DATE) {
      ($a,$b)=($self->_date($a),$self->_date($b));
      $a->type eq $b->type or $self->_fail('INVALID_TARGET','Comparison requires matching date precisions');
      $self->_step(16+length($a->fraction)+length($b->fraction));
      return $a->_compare($b);
   }
   if ($type==TYPE_NUMBER) {
      is_finite($a) && is_finite($b) or $self->_fail('INVALID_TARGET','Comparison requires finite numbers');
      ($a,$b)=($self->_number($a),$self->_number($b)) if ref($a) || ref($b);
      return $a<=>$b;
   }
   return $a<=>$b if $type==TYPE_BOOLEAN;
   if ($type==TYPE_STRING) {
      my $policy=$self->{options}{codepoint_policy} || 'preserve';
      if (!ref($policy) && $policy eq 'preserve') {
         $self->_step((length($a)+length($b))*.001);
         return $a cmp $b;
      }
      require JGraft::_String;
      my $av=JGraft::_String->_new($self,$a,'comparison');
      my $bv=JGraft::_String->_new($self,$b,'comparison');
      my $size=$av->{size}<$bv->{size}?$av->{size}:$bv->{size};
      $self->_step($size);
      for my $i (0..$size-1) { my $c=$av->_at($i)<=>$bv->_at($i); return $c if $c }
      return $av->{size}<=>$bv->{size};
   }
   if ($type==TYPE_ARRAY) {
      my $size=@$a<@$b?scalar @$a:scalar @$b;
      $self->_step($size);
      for my $i (0..$size-1) {
         $self->_present($a,$i) && $self->_present($b,$i) or $self->_fail('INVALID_TARGET','Comparison encounters a deleted element');
         my $c=$self->_compare_values($a->[$i],$b->[$i],$depth+1); return $c if $c;
      }
      return @$a<=>@$b;
   }
   $self->_fail('INVALID_TARGET','Values have no defined ordering');
}
sub JGraft::Expr::LESS::_execute {
   my ($expr,$self,$depth)=@_;
   my $a=$self->_input_value($expr,'expr_a',$depth);
   my $b=$self->_eval($expr->expr_b,$depth+1);
   return $self->_compare_values($a,$b,$depth+1)<0? JSON::PP::true : JSON::PP::false;
}
sub JGraft::Expr::LESSEQ::_execute {
   my ($expr,$self,$depth)=@_;
   my $a=$self->_input_value($expr,'expr_a',$depth);
   my $b=$self->_eval($expr->expr_b,$depth+1);
   return $self->_compare_values($a,$b,$depth+1)<=0? JSON::PP::true : JSON::PP::false;
}

sub _numeric_values {
   my ($self,$expr,$depth)= @_;
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
   for my $v (@values) { type_mask($v)==TYPE_NUMBER && is_finite($v) or $self->_fail('INVALID_TARGET','Arithmetic expects finite numbers') }
   @values=map $self->_number($_),@values if grep ref($_),@values;
   return @values;
}
sub _number {
   my ($self,$value)=@_;
   my $size=ref($value)?JGraft::Util::estimate_number_digits($value):32;
   $self->_step(1+$size*$size*.01);
   $self->_allocation(128+16*$size);
   my $out=eval { JGraft::Util::to_rational($value) };
   $@ and $self->_fail('UNSUPPORTED_GRAFT',"Numeric conversion: $@");
   return $out;
}
sub _finite_result {
   my ($self,$result)= @_;
   is_finite($result) or $self->_fail('INVALID_TARGET','Non-finite arithmetic result');
   if (ref $result) {
      my $size=length($result->bstr);
      $self->_step($size); $self->_allocation(128+8*$size);
   }
   return $result;
}
sub JGraft::Expr::ADD::_execute {
   my ($expr,$self,$depth)= @_;
   my $result=0;
   $result+=$_ for $self->_numeric_values($expr,$depth);
   return $self->_finite_result($result);
}
sub JGraft::Expr::MUL::_execute {
   my ($expr,$self,$depth)= @_;
   my $result=1;
   $result*=$_ for $self->_numeric_values($expr,$depth);
   return $self->_finite_result($result);
}
sub JGraft::Expr::SUB::_execute {
   my ($expr,$self,$depth)= @_;
   my ($a,$b)=$self->_numeric_values($expr,$depth);
   return $self->_finite_result($a-$b);
}
sub JGraft::Expr::DIV::_execute {
   my ($expr,$self,$depth)= @_;
   my ($a,$b)=$self->_numeric_values($expr,$depth);
   $b!=0 or $self->_fail('INVALID_TARGET','Division by zero');
   return $self->_finite_result($a/$b);
}
sub JGraft::Expr::MOD::_execute {
   my ($expr,$self,$depth)= @_;
   my ($a,$b)=$self->_numeric_values($expr,$depth);
   $b!=0 or $self->_fail('INVALID_TARGET','Division by zero');
   require POSIX;
   my $quotient=$a/$b;
   my $floor=ref($quotient)?$quotient->bfloor:POSIX::floor($quotient);
   return $self->_finite_result($a-$floor*$b);
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
      if (grep ref($_),($ofs,$len,$lim)) {
         ($ofs,$len,$lim)=map ref($_)?$self->_number($_):$_,($ofs,$len,$lim);
      }
      if (defined $ofs && defined $len && defined $lim && $ofs+$len!=$lim) { $self->_fail('INVALID_OPERAND','Inconsistent SLICE bounds') }
      $ofs=defined $len && defined $lim? $lim-$len : 0 unless defined $ofs;
   }
   else {
      $value=$self->_eval($expr->value_expr,$depth+1);
      $ofs=$self->_eval($expr->ofs,$depth+1);
      $len=$self->_eval($expr->len,$depth+1) if exists $expr->{len};
      is_integer($ofs) && (!exists $expr->{len} || is_integer($len)) or $self->_fail('INVALID_OPERAND','SLICE bounds must be integers');
      ($ofs,$len)=map ref($_)?$self->_number($_):$_,($ofs,$len) if ref($ofs) || ref($len);
   }
   my $type=type_mask($value);
   $type==TYPE_ARRAY || $type==TYPE_STRING or $self->_fail('INVALID_TARGET','SLICE expects an array or string');
   my $size=$type==TYPE_ARRAY? scalar @$value : length($value);
   $ofs+=$size if $ofs<0;
   $lim=defined $len? ($len<0?$size+$len:$ofs+$len) : $size unless defined $lim;
   $ofs>=0 && $ofs<=$lim && $lim<=$size or $self->_fail('INVALID_TARGET','SLICE is out of range');
   if (ref($ofs) || ref($lim)) {
      ($ofs,$lim)=map JGraft::Util::to_native_number($_),($ofs,$lim);
   }
   if ($type==TYPE_STRING) { $self->_step(($lim-$ofs)*.001); $self->_charge('mem',4*($lim-$ofs)); return substr($value,$ofs,$lim-$ofs) }
   my $out=$self->_new_array($lim-$ofs);
   $self->_step($lim-$ofs);
   for (my $i=$ofs;$i<$lim;++$i) {
      $self->_present($value,$i) or $self->_fail('INVALID_TARGET','SLICE contains a deleted element');
      push @$out,$value->[$i];
   }
   JGraft::_Split->_copy_meta($self,$value,$out,$ofs,$lim-$ofs) if $self->{split_meta}{refaddr($value)};
   $self->_mark_date_container($out) if $self->{date_containers}{refaddr($value)} && $lim>$ofs;
   return $out;
}

=head1 SYNOPSIS

  my $exec= JGraft::Exec->new(jgraft => $graft, undo => 1);
  my @result= $exec->apply($input);
  die $exec unless @result;
  my $output= $result[0];

=head1 DESCRIPTION

Executes JGRAFT, RAISE, AT, ATSPLIT, MATCH, IF, COPY, MOVE, and SPLICE with namespace references, value
construction, common expressions, structural matching, LOCAL, LENGTH, SLICE, SPLIT, JOIN,
CONCAT, REDUCE, FILTER, MAP, PROPS, MKOBJ, CASE, CURPROP, CAPTURE, arithmetic,
logical operators, comparisons, and boolean/number/string/date casts.

Math::BigInt, Math::BigFloat, Math::BigRat, and L<JGraft::JSON::Number> are numeric
values. Arithmetic involving one promotes its operands to copied Math::BigRat
values; it does not mutate the original objects or inherit global rational
rounding settings. Native-only arithmetic retains its usual fast path. Exact
results can be serialized by L<JGraft::JSON>; nonterminating rational results
require explicit rounding before JSON emission. Conversion and arithmetic costs
include conservative charges for digit counts and decimal exponent expansion.
Structural matching supports HAS, IS, ANY, ALL, NONE, EXISTS, ARRAY, NUM, BOOL,
STR, CHARS, DATE, and WITH. Array and string sequences support SEQ, SEQMIN, SEQMAX, REP, START, END,
successor unions/coverage assertions, and preferred named captures.
STR searches for the leftmost regex match over Unicode codepoints. Regex branching
uses the sequence engine; quoted literal runs use cached anchored Perl patterns.
Fuzzy matching remains unimplemented.
Unsupported protocol versions fail with UNSUPPORTED_GRAFT.

SPLICE resolves an existing array and normalizes its offset/count, then evaluates
all replacement values before editing. Replacements are individual values rather
than flattened arrays. Array shifting, metadata repair, copy-on-write, and undo
tracking are included in resource accounting. SPLIT metadata is spliced in parallel;
direct element references retain matching-origin rows and new values receive
adjacent formatting after the final order is known.

RAISE collects ordered diagnostics in C<logs>. Info/warn levels continue execution;
fail records its diagnostic and ends the attempt with NO_MATCH. Message expressions
must return printable strings without controls, surrogates, or noncharacters.
Optional data is evaluated before recording and held as a copy-on-write snapshot;
dates use the configured output formatter. A failed message/data evaluation emits
no record for that action. Earlier records remain available after failure.

SPLIT supports literal and longest-match regex separators, whole-field element
constraints, retained separators, and ordered left/right trimming. JOIN restores
hidden separators and trimming where present, using its default for new arrays.
Constant separators override captured separators; keep modes concatenate elements.
SPLIT never evaluates an unused default; JOIN does not evaluate trimming/element
patterns. ATSPLIT evaluates its path and configuration once in the selected-node
scope, edits a temporary array, and publishes the joined string only after its
subactions and reassembly succeed. Namespace side effects follow ordinary action
rules even if reassembly fails.

Hidden SPLIT metadata belongs to array instances within one execution. It is
preserved through copy-on-write, SLICE, and direct element references in array
construction and COPY/MOVE insertion. Overwrites retain destination formatting.
Transfers carry formatting only between arrays of the same origin; foreign or
new values inherit adjacent separators and preceding left trimming, without
copying right trimming. Function-derived element values do not carry formatting.
MOVE resolves adjacency in final element order, including on partial failure.
JSON serialization contains only visible array values; metadata is not imported
into a separate execution.

HAS/IS modes propagate through match structures. Match expressions evaluated by
functions start fresh matching state. INVALID_TARGET/INVALID_OPERAND encountered
while matching become mismatches; ANY/NONE trap those errors per alternative.
Fatal errors and resource limits propagate. Missing nodes remain distinct from
null and may be tested by EXISTS or negated predicates.

JGRAFT initializes constants in declaration order against the inherited common
expressions and parent stash, then installs its unevaluated common expressions
and starts a fresh stash. Inherited constants/expressions are shadowed locally;
EXPR references evaluate in the invoking scope. NODE follows the current node,
TEMP resets per action, and CONST/CAP are read-only. MATCH and successful IF
conditions replace CAP locally with their captures. IF's else action inherits CAP;
CAPTURE returns captures or false without changing CAP. Array captures contain
C<path>, C<ofs>, C<len>, and C<lim> and may be passed to SLICE.
EXPR aliases can supply action paths, with namespace and selector restrictions
checked against the resolved reference.

Unchanged subtrees may share storage with input. New containers are owned by an
execution generation. Copying a container freezes that generation; subsequent
writes shallow-clone the affected path. This also separates logical copies of
containers created earlier in the same execution. MOVE transfers ownership and
keeps deferred deletions/insertions attached to array identity until its end.

=constructor new

Options: C<jgraft>, optional C<input>, C<clone>, C<undo>, C<limits>,
C<codepoint_policy>, and C<date_format>. Limits
are estimated cumulative C<ops>, C<mem>, C<new_obj>, and maximum C<depth>. Defaults
are 1,000,000 operations, 64 MiB, 100,000 data containers, and depth 256. An explicit
undef disables an individual limit. Memory accounting is a conservative cumulative
allocation estimate including path and deferred-array scratch space; it does not
subtract reclaimed storage. Input and pre-existing graft containers are excluded
from new allocations. JSON-data graft compilation is conservatively precharged.

Strings contain Perl characters, not encoded UTF-8 octets. Unflagged bytes denote
U+0000 through U+00FF; callers must decode external encodings themselves. Regex
positions, LENGTH, SLICE, and capture bounds count codepoints, not graphemes.
String regex views use byte access for unflagged strings and a packed big-endian
four-byte codepoint buffer for flagged strings. Conversion and caches contribute
to resource counters. Input scalars and their regex positions are preserved.

C<codepoint_policy> controls surrogates (U+D800 through U+DFFF) and noncharacters
(U+FDD0 through U+FDEF and the final two codepoints of every Unicode plane):

=over

=item C<preserve> (default)

Repair Encode's substitutions to preserve each original codepoint in string views.

=item C<reject>

Abort with UNSUPPORTED_GRAFT when one of these codepoints is encountered, including
in input values, object keys, or graft literals, independently of regex execution.

=item C<substitute>

Keep Encode's default UTF-32BE substitutions in string regex views. The exact
substitutions depend on the installed Encode; Perl 5.8 can substitute NUL where
modern Encode substitutes U+FFFD. Stored input/output values are not rewritten;
SLICE still extracts original text at the corresponding character bounds.

=item A coderef

Called as C<< $callback->($codepoint, {index => $character_index, kind => $kind}) >>.
Return C<preserve>, C<reject>, or C<substitute> for that occurrence. C<kind> describes
the inspected source, such as C<input>, C<input key>, C<graft>, C<graft key>,
C<literal>, C<expression>, C<expression key>, C<subject>, C<pattern>, or
C<character class>. Validation and conversion can inspect the same text more than
once; decisions should be consistent. Callback exceptions propagate unchanged.

=back

Values above U+10FFFF always fail with UNSUPPORTED_GRAFT, regardless of policy.
Neither preserving nor substituting combines adjacent surrogate codepoints.

C<date_format> selects C<iso8601> (default), C<Time::Piece>, C<DateTime>, or a
callback receiving an immutable L<JGraft::Date>. Dates retain their type in
CONST/STASH/TEMP and expression values. Writes through NODE export them immediately,
including inside arrays/objects and ATSPLIT temporary roots. Later actions observe
the exported value. Unchanged native input dates retain their original format.

The executor caches each date's formatted result and weakly tracks containers
which may contain dates. Whole-container exports clone only affected branches;
borrowed input containers remain unchanged. Cached formatter results can be shared
between output occurrences, subject to the same read-only sharing rule as other
output values. Callback results are used as supplied, and callback exceptions
propagate unchanged. Built-in conversion failures produce UNSUPPORTED_GRAFT.

Time::Piece exports use UTC and reject fractional/leap seconds. DateTime exports
preserve nanoseconds and fixed offsets, require DateTime only when requested, and
reject unsupported precision/ranges. See L<JGraft::Date> for native precision
limitations. CASTSTR always uses ISO8601, independently of C<date_format>.
Undo serializes dates as CASTDATE expressions; choose the appropriate formatter
when applying undo to restore a native representation.

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

=attribute logs

An arrayref of ordered RAISE diagnostics. Each entry has numeric C<level>
(0 info, 1 warn, 2 fail), C<message>, and C<data> only when supplied, including
explicit null. Fatal entries are included. Each C<apply> starts a fresh array;
records from earlier applications remain valid. Treat records and their shared
data as read-only, like shared input/output. Logging does not print or warn.

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
