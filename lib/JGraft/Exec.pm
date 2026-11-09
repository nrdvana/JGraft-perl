package JGraft::Exec;
# VERSION
# ABSTRACT: Execute JGrafts with copy-on-write ownership
use strict;
use warnings;
no warnings 'recursion';
use Carp 'croak';
use Scalar::Util qw(blessed refaddr);
use JSON::PP ();
use JGraft::_ExecStore;
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
   local $JGraft::JSON::Object::EXEC;
   local $JGraft::JSON::Number::EXEC;
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
   $self->_init_application($input);
   my $ok= eval {
      local $JGraft::JSON::Object::EXEC=$self;
      local $JGraft::JSON::Number::EXEC=$self;
      local ($Math::BigRat::accuracy,$Math::BigRat::precision);
      if ($self->{options}{undo}) {
         require JGraft::_Undo;
         $self->{undo_state}= JGraft::_Undo->_new($self,$input);
         $self->_reserve(0,192,0);
      }
      $self->_inspect_tree($input,0,0);
      $self->{temp}= [$self->_alloc_hash(0),1];
      $self->{stash}= [$self->_alloc_hash(0),1];
      $self->{const}= [$self->_alloc_hash(0),1];
      $self->{expr}= [$self->_alloc_hash(0),1];
      $self->{cap}= [$self->_alloc_hash(0),1];
      my $graft= $self->{options}{jgraft};
      $self->_inspect_tree($graft,1,!is_action($graft));
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
   my $expected=$ok || blessed($err) && refaddr($err)==refaddr($self);
   $self->{output}=$self->{root}[0] if !$ok && $expected && $self->{root}[1];
   $self->_release_application;
   unless ($ok) {
      die $err unless $expected;
      return;
   }
   return $self->{output};
}

sub _init_application {
   my ($self,$input)=@_;
   delete @{$self}{qw(error message diagnostic success undo output)};
   delete $self->{path_remap};
   $self->{count}= {ops=>0,mem=>0,new_obj=>0,depth=>0};
   $self->{scratch_mem}=0;
   $self->{logs}= [];
   $self->{containers}= {};
   $self->{next_container_id}=0;
   delete $self->{undo_state};
   $self->{move_batch}= [];
   $self->{regex_literals}= {};
   $self->{char_classes}= {};
   $self->{has_split}=0;
   $self->{split_origin}= 0;
   $self->{dates}= {};
   $self->{date_output}= {};
   $self->{epoch}= 1;
   $self->{revision}=0;
   $self->{root}= [$input,1];
   $self->{current}= [$self->{root},[]];
}

sub _release_application {
   my $self=shift;
   delete @{$self}{qw(temp stash const expr cap containers dates date_output
      regex_literals char_classes move_batch has_split split_origin path_remap)};
   # Keep the stable root cell usable by diagnostics/private budget helpers,
   # without retaining the pre-clone result or a discarded original tree.
   @{$self->{root}}=exists($self->{output})?($self->{output},1):(undef,0);
   $self->{current}=[$self->{root},[]];
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
sub _run {
   my ($self,$action,$depth)= @_;
   $self->_enter($depth);
   is_action($action) or $self->_fail('INVALID_GRAFT','Expected an action object');
   local $self->{action}=$action;
   local $self->{temp}=[$self->_alloc_hash(0),1];
   return $action->_execute($self,$depth);
}

# Keep action execution methods alongside expression execution methods in this
# module, with per-action context and TEMP lifetime managed by _run above.
sub JGraft::Action::_execute {
   my ($action,$self)= @_;
   $self->_fail('UNSUPPORTED_GRAFT','Action '.$action->name.' is not implemented');
}
sub JGraft::Action::JGRAFT::_execute {
   my ($action,$self,$depth)= @_;
   my $meta=$action->{metadata};
   if (exists $meta->{v} && $meta->{v}>1) { $self->_fail('UNSUPPORTED_GRAFT','Unsupported JGraft version') }
   local $self->{const}= $self->{const};
   local $self->{expr}= $self->{expr};
   for my $ns ('const','expr') {
      next unless exists $meta->{$ns};
      my $copy=$self->_copy_hash($self->{$ns}[0]);
      $self->{$ns}=[$copy,1];
      my $defs=$meta->{$ns};
      $self->_tick(scalar @$defs);
      for (my $i=0;$i<@$defs;$i+=2) {
         my $key=$defs->[$i];
         $key="$key";
         my $v=$ns eq 'const'? $self->_eval($defs->[$i+1],$depth+1) : $defs->[$i+1];
         $self->_publish($v) if $ns eq 'const';
         $self->_assign([$self->{$ns},[$key]],$v);
      }
   }
   local $self->{stash}=[$self->_alloc_hash(0),1];
   $self->_tick(scalar @{$action->{actions}});
   $self->_run($_,$depth+1) for @{$action->{actions}};
}
sub JGraft::Action::MATCH::_execute {
   my ($action,$self,$depth)= @_;
   my $captures=$self->_match($action->{match_spec},$depth+1,1);
   $captures or $self->_fail('NO_MATCH','Current node does not match');
   local $self->{cap}=[$captures,1];
   $self->_tick(scalar @{$action->{actions}});
   $self->_run($_,$depth+1) for @{$action->{actions}};
}
sub JGraft::Action::IF::_execute {
   my ($action,$self,$depth)= @_;
   $self->_tick(scalar @{$action->{branches}});
   for my $branch (@{$action->{branches}}) {
      my $captures=$self->_match($branch->[0],$depth+1,1);
      next unless $captures;
      local $self->{cap}=[$captures,1];
      $self->_run($branch->[1],$depth+1);
      return;
   }
   $self->_run($action->{else_action},$depth+1) if exists $action->{else_action};
}
sub JGraft::Action::AT::_execute {
   my ($action,$self,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{path_workspace}=[$scratch_base,0];
   my $loc=$self->_expand_path($action->{path},'at',$depth+1);
   my $canonical=$self->_resolve($loc,'read')->{location};
   local $self->{current}=$canonical;
   $self->_tick(scalar @{$action->{actions}});
   $self->_run($_,$depth+1) for @{$action->{actions}};
}
sub JGraft::Action::COPY::_execute {
   my ($action,$self,$depth)= @_;
   my $pairs=$action->{assignments};
   $self->_tick(scalar @$pairs);
   for my $pair (@$pairs) {
      my $scratch_base=$self->{scratch_mem};
      local $self->{scratch_mem}=$scratch_base;
      local $self->{path_workspace}=[$scratch_base,0];
      $self->_path_scratch(128); # Element provenance survives source evaluation.
      my $metadata;
      my $v=$self->_eval($pair->[0],$depth+1,\$metadata);
      # Keep the value stable even if destination expressions read from it.
      $self->_publish($v);
      my $loc=$self->_expand_path($pair->[1],'write',$depth+1);
      my $dest=$self->_resolve($loc,'write');
      $self->_assign($dest,$v,$metadata);
   }
}
sub JGraft::Action::MOVE::_execute {
   my ($action,$self,$depth)= @_;
   return $self->_move($action->{moves},$depth+1);
}
sub JGraft::Action::RAISE::_execute {
   no warnings 'utf8';
   my ($action,$self,$depth)=@_;
   my $message=$self->_eval($action->{message},$depth+1);
   type_mask($message)==TYPE_STRING or $self->_fail('INVALID_TARGET','RAISE message must be a string');
   $self->_tick(length($message));
   while ($message =~ /(.)/gs) {
      my $cp=ord($1);
      ($cp<32 || ($cp>=127 && $cp<=159) || ($cp>=0xd800 && $cp<=0xdfff)
         || ($cp>=0xfdd0 && $cp<=0xfdef) || ($cp & 0xffff)>=0xfffe)
         and $self->_fail('INVALID_TARGET','RAISE message contains a forbidden character');
   }
   my $level=$action->{level};
   $level={info=>0,warn=>1,fail=>2}->{$level} if type_mask($level)==TYPE_STRING;
   my $entry=$self->_alloc_hash(exists($action->{data})?3:2);
   @$entry{qw(level message)}=($level,$message);
   if (exists $action->{data}) {
      $entry->{data}=$self->_publish($self->_eval($action->{data},$depth+1),1,$depth+1);
   }
   $self->_reserve(0,16+4*length($message),0);
   push @{$self->{logs}},$entry;
   $self->_fail('NO_MATCH',$message) if $level==2;
}
sub JGraft::Action::SPLICE::_execute {
   my ($action,$self,$depth)=@_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{path_workspace}=[$scratch_base,0];
   my $loc=$self->_expand_path($action->{array_elem_path},'write',$depth+1);
   @{$loc->[1]} or $self->_fail('INVALID_TARGET','SPLICE requires an array element path');
   my $trace=$self->_resolve($loc,'write');
   my $frame=$trace->{frames}[-1];
   $frame->[_F_KIND]==TYPE_ARRAY && defined($frame->[_F_CONTAINER])
      or $self->_fail('INVALID_TARGET','SPLICE requires an array element path');
   my ($array,$offset)=@$frame[_F_CONTAINER,_F_KEY];
   my $count=$self->_eval($action->{count_expr},$depth+1);
   !defined($count) || is_integer($count) or $self->_fail('INVALID_OPERAND','SPLICE count must be an integer or null');
   my $size=@$array;
   $count=$size-$offset unless defined $count;
   $count+=$size-$offset if $count<0;
   $count>=0 && $count<=$size-$offset or $self->_fail('INVALID_TARGET','SPLICE count is out of range');
   my (@values,@sources);
   $self->_tick(scalar @{$action->{replacements}});
   my $workspace=160*@{$action->{replacements}}; # Values, sources, and provenance.
   $self->_path_scratch($workspace);
   for my $arg (@{$action->{replacements}}) {
      my $source;
      my $value=$self->_eval($arg,$depth+1,\$source);
      push @values,$self->_publish($value,($loc->[2] || '') eq 'node' || refaddr($loc->[0])==refaddr($self->{root}),$depth+1);
      push @sources,$source;
   }
   return unless $count || @values;
   $self->_splice($trace,$offset,$count,\@values,\@sources);
}
sub JGraft::Action::ATSPLIT::_execute {
   my ($action,$self,$depth)=@_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{path_workspace}=[$scratch_base,0];
   require JGraft::_Split;
   my $target_trace=$self->_resolve($self->_expand_path($action->{path},'at',$depth+1),'read');
   my ($text,$target)=@$target_trace{qw(value location)};
   $self->_path_scratch(512); # Resolved config and optional raw-spec wrapper.
   my ($config,$result);
   {
      local $self->{current}=$target;
      $config=JGraft::_Split->_config($self,$action->{split_spec},$depth+1,'both');
      my $array=JGraft::_Split->_split($self,$config,$text,$depth+1);
      local $self->{current}=[[$array,1],[]];
      local $self->{match_cursor};
      $self->_tick(scalar @{$action->{actions}});
      $self->_run($_,$depth+1) for @{$action->{actions}};
      $result=JGraft::_Split->_join($self,$config,$self->_read_value($self->{current}),$depth+1);
   }
   $self->_assign($target_trace,$result);
}

sub _match {
   my ($self,$spec,$depth,$observable)=@_;
   require JGraft::_Match;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   $self->_scratch_set($scratch_base,288); # Private match state and root cursor.
   my $state=JGraft::_Match->_new($self,$observable);
   my ($cell,$parts)=@{$self->{current}};
   my ($value,$exists)=@$cell;
   my $parent;
   $self->_tick(scalar @$parts);
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
   return $state->_test($spec,$cursor,$depth,0)? $state->{captures} : undef;
}

sub _macro {
   my ($self,$expr,$depth)= @_;
   my $name=$self->_eval($expr->{expr_name},$depth+1);
   my $t=type_mask($name);
   $t==TYPE_STRING || ($t==TYPE_NUMBER && is_integer($name)) or $self->_fail('INVALID_OPERAND','Invalid EXPR name');
   my $key="$name";
   exists $self->{expr}[0]{$key} or $self->_fail('INVALID_TARGET','Unknown common expression');
   return $self->{expr}[0]{$key};
}
sub _eval {
   my ($self,$v,$depth,$source)= @_;
   my $expression=is_expr($v);
   if ($source) {
      $$source=undef;
      $self->_enter($depth);
      if ($expression) {
         local $self->{expression}=$v;
         return $self->_eval($self->_macro($v,$depth+1),$depth+1,$source) if $v->name eq 'EXPR';
         if ($v->is_ref && exists $v->{path}) {
            my $base=$self->{scratch_mem};
            local $self->{scratch_mem}=$base;
            local $self->{path_workspace}=[$base,0];
            return $self->_read_value($self->_expand_path($v,'read',$depth+1),$source);
         }
      }
      ++$depth;
   }
   $self->_enter($depth);
   if ($expression) {
      local $self->{expression}=$v;
      my $result=$v->_execute($self,$depth);
      $self->_check_string($result,'expression') if type_mask($result)==TYPE_STRING;
      return $result;
   }
   my $t=type_mask($v);
   return $self->_date($v) if $t==TYPE_DATE;
   if ($t==TYPE_ARRAY) {
      my $out=$self->_alloc_array(scalar @$v);
      $self->_tick(scalar @$v);
      my $scratch_base=$self->{scratch_mem};
      local $self->{scratch_mem}=$scratch_base;
      $self->_scratch_set($scratch_base,128); # One live element provenance record.
      for my $i (0..$#$v) {
         my $metadata;
         my $value=$self->_eval($v->[$i],$depth+1,\$metadata);
         $self->_append_value($out,$value,$metadata);
      }
      return $out;
   }
   if ($t==TYPE_OBJECT) {
      my $tie=tied %$v;
      if ($tie && $tie->isa('JGraft::JSON::Object')) {
         my $out=$self->_own($tie->_clone(sub { $self->_eval($_[0],$depth+1) }));
         $self->_mark_date_container($out) if $self->_contains_date($v);
         return $out;
      }
      my $scratch_base=$self->{scratch_mem};
      local $self->{scratch_mem}=$scratch_base;
      $self->_scratch_set($scratch_base,80+16*keys %$v);
      my $out=$self->_alloc_hash(scalar keys %$v);
      $self->_tick(scalar keys %$v);
      for my $key (keys %$v) {
         $self->_check_string($key,'expression key');
         $self->_set_member($out,$key,$self->_eval($v->{$key},$depth+1));
      }
      return $out;
   }
   $self->_tick(length($v)*.001) if $t==TYPE_STRING;
   $self->_check_string($v,'literal') if $t==TYPE_STRING;
   $t==TYPE_NULL || $t==TYPE_BOOLEAN || $t==TYPE_NUMBER || $t==TYPE_STRING or $self->_fail('UNSUPPORTED_GRAFT','Unsupported literal value');
   return $v;
}
sub _input_value {
   my ($self,$expr,$field,$depth)= @_;
   return $self->_eval($expr->{$field},$depth+1) if exists $expr->{$field};
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{path_workspace}=[$scratch_base,0];
   return $self->_read_value($self->{current});
}
# Install execution methods here so parsing-only users need not load them.
# References and match expressions inherit their category's common handler.
sub JGraft::Expr::_execute {
   my ($expr,$self)= @_;
   $self->_fail('UNSUPPORTED_GRAFT','Expression '.$expr->name.' is not implemented');
}
sub JGraft::Expr::Ref::_execute {
   my ($expr,$self,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{path_workspace}=[$scratch_base,0];
   return $self->_read_value($self->_expand_path($expr,'read',$depth+1));
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
   my $captures=$self->_match($expr->{match_expr},$depth+1,1);
   return $captures? $captures : JSON::PP::false;
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
   if ($t==TYPE_STRING) { $self->_tick(length($v)*.001); return length($v) }
   $self->_fail('INVALID_TARGET','LENGTH expects an array or string');
}
sub JGraft::Expr::SLICE::_execute {
   my ($expr,$self,$depth)= @_;
   return $self->_slice($expr,$depth+1);
}
sub JGraft::Expr::SPLIT::_execute {
   my ($expr,$self,$depth)=@_;
   require JGraft::_Split;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   $self->_scratch_set($scratch_base,512);
   my $config=JGraft::_Split->_config($self,$expr->{split_spec},$depth+1,'split');
   return JGraft::_Split->_split($self,$config,$self->_input_value($expr,'string_expr',$depth),$depth+1);
}
sub JGraft::Expr::JOIN::_execute {
   my ($expr,$self,$depth)=@_;
   require JGraft::_Split;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   $self->_scratch_set($scratch_base,512);
   my $config=JGraft::_Split->_config($self,$expr->{split_spec},$depth+1,'join');
   return JGraft::_Split->_join($self,$config,$self->_input_value($expr,'array_expr',$depth),$depth+1);
}
sub JGraft::Expr::LOCAL::_execute {
   my ($expr,$self,$depth)= @_;
   my $copy=$self->_copy_hash($self->{temp}[0]);
   local $self->{temp}=[$copy,1];
   local $self->{current}=$self->{current};
   local $self->{match_cursor}=$self->{match_cursor};
   $self->_tick(scalar @{$expr->{bindings}});
   for my $pair (@{$expr->{bindings}}) {
      my $key=$self->_eval($pair->[0],$depth+1);
      my $t=type_mask($key);
      $t==TYPE_NULL || $t==TYPE_STRING || ($t==TYPE_NUMBER && is_finite($key)) or $self->_fail('INVALID_OPERAND','Invalid LOCAL property');
      my $value=$self->_eval($pair->[1],$depth+1);
      if (!defined $key) { $self->{current}=[[$value,1],[]]; $self->{match_cursor}=undef }
      else { $self->_set_member($self->{temp}[0],"$key",$value) }
   }
   return $self->_eval($expr->{return_value_expr},$depth+1);
}

sub JGraft::Expr::CONCAT::_execute {
   my ($expr,$self,$depth)=@_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my ($type,$size,@values);
   $size=0;
   $self->_tick(scalar @{$expr->{value_exprs}});
   $self->_scratch_set($scratch_base,16*@{$expr->{value_exprs}});
   for my $arg (@{$expr->{value_exprs}}) {
      my $value=$self->_eval($arg,$depth+1);
      my $t=type_mask($value);
      ($t==TYPE_STRING || $t==TYPE_ARRAY) && (!defined($type) || $type==$t)
         or $self->_fail('INVALID_TARGET','CONCAT expects homogeneous arrays or strings');
      $type=$t;
      $size+=$t==TYPE_ARRAY? scalar @$value : length($value);
      push @values,$value;
   }
   if ($type==TYPE_STRING) {
      $self->_tick($size*.001); $self->_reserve(0,4*$size,0);
      return join('',@values);
   }
   my $out=$self->_alloc_array($size);
   $self->_append_range($out,$_,0,scalar @$_) for @values;
   if ($self->_split_meta($out)) {
      $self->_reserve(0,96*$size,0);
      JGraft::_Split->_fill_meta($self,$out);
   }
   return $out;
}

# Each callback sees the original element and its original index. Localizing
# both fields also isolates callbacks from an enclosing match cursor.
sub _iterate_array {
   my ($self,$expr,$depth,$mode)=@_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $acc=$self->_eval($expr->{initial_value},$depth+1) if $mode eq 'reduce';
   my $array=$self->_input_value($expr,'array_expr',$depth);
   type_mask($array)==TYPE_ARRAY or $self->_fail('INVALID_TARGET','Array iteration expects an array');
   $self->_tick(scalar @$array);
   $self->_scratch_set($scratch_base,80);
   my $out=$self->_alloc_array(scalar @$array) unless $mode eq 'reduce';
   my $meta=$self->_split_meta($array);
   my @selected;
   $self->_scratch_set($scratch_base,80+16*@$array) if $meta && $mode eq 'filter';
   if ($mode eq 'map') {
      @$out=(undef)x scalar @$array;
      JGraft::_Split->_copy_meta($self,$array,$out,0,scalar @$array) if $meta;
   }
   local $self->{temp}=$self->{temp};
   if ($mode eq 'reduce') {
      my $temp=$self->_copy_hash($self->{temp}[0]);
      $self->{temp}=[$temp,1];
   }
   local $self->{current}=$self->{current};
   local $self->{match_cursor};
   for my $i (0..$#$array) {
      $self->_present($array,$i) or $self->_fail('INVALID_TARGET','Array iteration encounters a deleted element');
      $self->{current}=[[$array,1],[$i]];
      if ($mode eq 'reduce') {
         $self->_set_member($self->{temp}[0],$expr->{temp_prop},$acc);
         $acc=$self->_eval($expr->{reduce_expr},$depth+1);
      }
      elsif ($mode eq 'filter') {
         if ($self->_match($expr->{match_expr},$depth+1)) {
            push @$out,$array->[$i];
            push @selected,$i if $meta;
         }
      }
      else { $self->_set_member($out,$i,$self->_eval($expr->{transform_expr},$depth+1)) }
   }
   return $acc if $mode eq 'reduce';
   JGraft::_Split->_copy_meta($self,$array,$out,0,scalar(@selected),\@selected) if $mode eq 'filter' && $meta;
   $self->_mark_date_container($out) if $mode eq 'filter' && @$out && $self->_contains_date($array);
   return $out;
}
sub JGraft::Expr::REDUCE::_execute { $_[1]->_iterate_array($_[0],$_[2],'reduce') }
sub JGraft::Expr::FILTER::_execute { $_[1]->_iterate_array($_[0],$_[2],'filter') }
sub JGraft::Expr::MAP::_execute { $_[1]->_iterate_array($_[0],$_[2],'map') }

sub JGraft::Expr::PROPS::_execute {
   my ($expr,$self,$depth)=@_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $object=$self->_input_value($expr,'object_expr',$depth);
   type_mask($object)==TYPE_OBJECT or $self->_fail('INVALID_TARGET','PROPS expects an object');
   my $n=keys %$object;
   my $levels=1; $levels++ while 2**$levels<$n;
   $self->_tick($n*$levels);
   $self->_scratch_set($scratch_base,16*$n);
   my @keys=sort { $self->_compare_values($a,$b,$depth+1) } keys %$object;
   my $options=$expr->{options} || 0;
   my $out=$self->_alloc_array($options==2?2:$n);
   my ($names,$values);
   if ($options==2) { $names=$self->_alloc_array($n); $values=$self->_alloc_array($n); @$out=($names,$values) }
   for my $key (@keys) {
      $self->_check_string($key,'expression key');
      if (!$options) { push @$out,$key }
      elsif ($options==1) {
         my $pair=$self->_alloc_array(2);
         $self->_set_member($pair,0,$key); $self->_set_member($pair,1,$object->{$key});
         $self->_set_member($out,scalar @$out,$pair);
      }
      else { push @$names,$key; $self->_set_member($values,scalar @$values,$object->{$key}) }
   }
   $self->_mark_date_container($out) if $options==2 && $self->_contains_date($values);
   return $out;
}
sub JGraft::Expr::MKOBJ::_execute {
   my ($expr,$self,$depth)=@_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $workspace=0;
   my @pairs;
   if (exists $expr->{prop_array_expr}) {
      my $pairs=$self->_eval($expr->{prop_array_expr},$depth+1);
      type_mask($pairs)==TYPE_ARRAY or $self->_fail('INVALID_TARGET','MKOBJ expects property pairs');
      $self->_tick(scalar @$pairs); $self->_scratch_set($scratch_base,16*@$pairs);
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
      $self->_tick(scalar @{$expr->{value_exprs}});
      $workspace=32*@{$expr->{value_exprs}};
      $self->_scratch_set($scratch_base,$workspace);
      push @args,$self->_eval($_,$depth+1) for @{$expr->{value_exprs}};
      @args && @args%2==0 or $self->_fail('INVALID_TARGET','MKOBJ expects property pairs');
      if (@args==2 && type_mask($args[0])==TYPE_ARRAY && type_mask($args[1])==TYPE_ARRAY) {
         my ($names,$values)=@args;
         @$names==@$values or $self->_fail('INVALID_TARGET','MKOBJ array lengths differ');
         $self->_tick(scalar @$names); $self->_scratch_set($scratch_base,$workspace+48*@$names);
         for my $i (0..$#$names) {
            $self->_present($names,$i) && $self->_present($values,$i) or $self->_fail('INVALID_TARGET','Deleted MKOBJ element');
            push @pairs,[$names->[$i],$values->[$i]];
         }
      }
      else { for (my $i=0;$i<@args;$i+=2) { push @pairs,[@args[$i,$i+1]] } }
   }
   my $out=$self->_alloc_hash(scalar @pairs);
   $self->_tick(scalar @pairs);
   for my $pair (@pairs) {
      my ($key,$value)=@$pair;
      type_mask($key)==TYPE_STRING or $self->_fail('INVALID_TARGET','MKOBJ names must be strings');
      $self->_check_string($key,'expression key');
      $self->_tick(length($key)*.001);
      exists $out->{$key} and $self->_fail('INVALID_TARGET','Duplicate MKOBJ property');
      $self->_set_member($out,$key,$value);
   }
   return $out;
}
sub JGraft::Expr::CASE::_execute {
   my ($expr,$self,$depth)=@_;
   $self->_tick(scalar @{$expr->{branches}});
   for my $pair (@{$expr->{branches}}) {
      return $self->_eval($pair->[1],$depth+1) if $self->_match($pair->[0],$depth+1);
   }
   return $self->_eval($expr->{else_value_expr},$depth+1) if exists $expr->{else_value_expr};
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
   $self->_tick(scalar @{$expr->{value_exprs}});
   for my $arg (@{$expr->{value_exprs}}) {
      return JSON::PP::false unless $self->_boolean_value($arg,$depth+1);
   }
   return JSON::PP::true;
}
sub JGraft::Expr::OR::_execute {
   my ($expr,$self,$depth)= @_;
   $self->_tick(scalar @{$expr->{value_exprs}});
   for my $arg (@{$expr->{value_exprs}}) {
      return JSON::PP::true if $self->_boolean_value($arg,$depth+1);
   }
   return JSON::PP::false;
}
sub JGraft::Expr::NOT::_execute {
   my ($expr,$self,$depth)= @_;
   $self->_tick(scalar @{$expr->{value_exprs}});
   for my $arg (@{$expr->{value_exprs}}) {
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
   if ($t==TYPE_STRING) {
      $self->_tick(length($v)*.001);
      $v =~ /\A[+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?\z/
         or $self->_fail('INVALID_TARGET','Invalid CASTNUM input');
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
      $self->_tick(length($date->fraction)*.01+1);
      my $out=$date->to_iso8601;
      $self->_reserve(0,length($out),0);
      return $out;
   }
   if ($t==TYPE_NUMBER) {
      my $out;
      if (ref $v) {
         my $scratch_base=$self->{scratch_mem};
         local $self->{scratch_mem}=$scratch_base;
         my $size=JGraft::Util::estimate_number_digits($v);
         # A finite decimal needs at most log2(10) places per denominator
         # digit. Cover factoring/scaling copies and reserve the escaping text
         # before conversion; the rational itself is private to this call.
         my $characters=4*$size+4;
         my $workspace=[$scratch_base,128+64*$characters];
         $self->_scratch_set(@$workspace);
         $self->_reserve(1+$characters*$characters*.01,$characters,0);
         my $number=$self->_number($v,$workspace,$size);
         $out=eval { JGraft::Util::to_decimal_string($number) };
         $@ and $self->_fail('UNSUPPORTED_GRAFT',"$@");
         return $out;
      }
      my $integer=is_integer($v);
      # Support negative zero via sprintf. Check integer typing before older
      # Perls can add string flags while producing the native spelling.
      $out= $v? "$v" : sprintf('%g', $v);
      # If scientific notation was used for an integer, expand the digits.
      if ($integer && $out =~ /\A(-?)([0-9]+)(?:\.([0-9]+))?[eE]([+-]?[0-9]+)\z/) {
         my ($sign,$whole,$fraction,$exponent)=($1,$2,defined($3)?$3:'',0+$4);
         my $length=length($sign)+length($whole)+$exponent;
         $self->_tick($length*.001); $self->_reserve(0,$length,0);
         my $digits=$whole.$fraction;
         my $zeros=$exponent-length($fraction);
         $out=$sign.($zeros>=0? $digits.('0'x$zeros) : substr($digits,0,length($digits)+$zeros));
      }
      else { $self->_tick(length($out)*.001); $self->_reserve(0,length($out),0) }
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
   $self->_enter($depth);
   my $type=type_mask($a);
   $type==type_mask($b) or $self->_fail('INVALID_TARGET','Comparison requires matching types');
   if ($type==TYPE_DATE) {
      ($a,$b)=($self->_date($a),$self->_date($b));
      $a->type eq $b->type or $self->_fail('INVALID_TARGET','Comparison requires matching date precisions');
      $self->_tick(16+length($a->fraction)+length($b->fraction));
      return $a->_compare($b);
   }
   if ($type==TYPE_NUMBER) {
      is_finite($a) && is_finite($b) or $self->_fail('INVALID_TARGET','Comparison requires finite numbers');
      if (ref($a) || ref($b)) {
         my $scratch_base=$self->{scratch_mem};
         local $self->{scratch_mem}=$scratch_base;
         my $workspace=[$scratch_base,0];
         ($a,$b)=($self->_number($a,$workspace),$self->_number($b,$workspace));
         return $a<=>$b;
      }
      return $a<=>$b;
   }
   return $a<=>$b if $type==TYPE_BOOLEAN;
   if ($type==TYPE_STRING) {
      my $policy=$self->{options}{codepoint_policy} || 'preserve';
      if (!ref($policy) && $policy eq 'preserve') {
         $self->_tick((length($a)+length($b))*.001);
         return $a cmp $b;
      }
      require JGraft::_String;
      my $scratch_base=$self->{scratch_mem};
      local $self->{scratch_mem}=$scratch_base;
      $self->_scratch_set($scratch_base,JGraft::_String->_workspace($a)+JGraft::_String->_workspace($b));
      my $av=JGraft::_String->_new($self,$a,'comparison',undef,1);
      my $bv=JGraft::_String->_new($self,$b,'comparison',undef,1);
      my $size=$av->{size}<$bv->{size}?$av->{size}:$bv->{size};
      $self->_tick($size);
      for my $i (0..$size-1) { my $c=$av->_at($i)<=>$bv->_at($i); return $c if $c }
      return $av->{size}<=>$bv->{size};
   }
   if ($type==TYPE_ARRAY) {
      my $size=@$a<@$b?scalar @$a:scalar @$b;
      $self->_tick($size);
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
   my $b=$self->_eval($expr->{expr_b},$depth+1);
   return $self->_compare_values($a,$b,$depth+1)<0? JSON::PP::true : JSON::PP::false;
}
sub JGraft::Expr::LESSEQ::_execute {
   my ($expr,$self,$depth)=@_;
   my $a=$self->_input_value($expr,'expr_a',$depth);
   my $b=$self->_eval($expr->{expr_b},$depth+1);
   return $self->_compare_values($a,$b,$depth+1)<=0? JSON::PP::true : JSON::PP::false;
}

sub _numeric_values {
   my ($self,$expr,$depth,$workspace)= @_;
   my @values;
   $workspace->[1]+=80+32*(exists($expr->{value_exprs})? scalar @{$expr->{value_exprs}} : 2);
   $self->_scratch_set(@$workspace);
   if (exists $expr->{value_exprs}) {
      $self->_tick(scalar @{$expr->{value_exprs}});
      @values=map $self->_eval($_,$depth+1), @{$expr->{value_exprs}};
      if (@values==1 && ref $values[0] eq 'ARRAY') {
         my $array=$values[0];
         $self->_tick(scalar @$array);
         $workspace->[1]+=32*@$array;
         $self->_scratch_set(@$workspace);
         for my $i (0..$#$array) { $self->_present($array,$i) or $self->_fail('INVALID_TARGET','Deleted array element') }
         @values=@$array;
      }
   }
   else { @values=map $self->_eval($expr->{$_},$depth+1), qw(value_expr1 value_expr2) }
   $self->_tick(scalar @values);
   for my $v (@values) { type_mask($v)==TYPE_NUMBER && is_finite($v) or $self->_fail('INVALID_TARGET','Arithmetic expects finite numbers') }
   if (grep ref($_),@values) {
      for my $i (0..$#values) { $values[$i]=$self->_number($values[$i],$workspace) }
   }
   return \@values;
}
sub _number {
   my ($self,$value,$workspace,$size)=@_;
   unless (defined $size) {
      $size=JGraft::Util::estimate_number_digits($value);
      $size=32 if !ref($value) && $size<32;
   }
   $self->_tick(1+$size*$size*.01);
   # All callers consume the copy within their own reservation. Result values
   # have separate retained charges; copying still counts as an allocation.
   $self->_reserve(0,0,1);
   $workspace->[1]+=192+16*$size;
   $self->_scratch_set(@$workspace);
   my $out=eval { JGraft::Util::to_rational($value) };
   my $error=$@;
   die $error if ref $error;
   $self->_fail('UNSUPPORTED_GRAFT',"Numeric conversion: $error") if $error;
   return $out;
}
sub _finite_result {
   my ($self,$result)= @_;
   is_finite($result) or $self->_fail('INVALID_TARGET','Non-finite arithmetic result');
   return $result;
}
# The arithmetic call owns operand copies plus a reusable accumulator/workspace.
# An escaping final result is paid before the operation, using a digit bound;
# intermediate results remain covered until the next step consumes them.
# workspace = [outer scratch, fixed operand bytes, current accumulator bytes].
sub _exact_step {
   my ($self,$op,$a,$b,$workspace,$final)=@_;
   my ($base,$floor)=@$workspace;
   my $accumulator=$workspace->[2] || 0;
   $self->_scratch_set($base,$floor+512+$accumulator);
   is_finite($a) && is_finite($b) or $self->_fail('INVALID_TARGET','Non-finite arithmetic result');
   my $class=ref($b) || ref($a);
   my $lib=$class->config('lib');
   my ($an,$ad,$ai,$as,$az,$ao,$alen)=JGraft::Util::_rational_shape($a,$lib);
   my ($bn,$bd,$bi,$bs,$bz,$bo,$blen)=JGraft::Util::_rational_shape($b,$lib);
   $self->_tick(1+($alen+$blen)*($alen+$blen)*.01);
   my ($n,$d,$integer,$negative);
   if ($op eq 'add' || $op eq 'sub') {
      $n=($an+$bd>$bn+$ad?$an+$bd:$bn+$ad)+1;
      $d=$ad+$bd;
      $integer=$ai && $bi;
      $negative=1; # Either sign is possible before adding/subtracting.
   }
   elsif ($op eq 'mul' || $op eq 'div') {
      ($n,$d)=$op eq 'mul'?($an+$bn,$ad+$bd):($an+$bd,$ad+$bn);
      $integer=$op eq 'mul' && $ai && $bi;
      $negative=$as!=$bs?1:0;
   }
   else { # Floor modulus: the remainder has the divisor's sign and magnitude.
      $n=$ai && $bi?$bn:$bn+$ad+1;
      $d=$ad+$bd;
      $integer=$ai && $bi;
      $negative=$bs;
   }
   my $size=$n+$negative+($integer?0:1+$d);
   my $digits=$an+$bd+$bn+$ad+$n+$d;
   $digits+=2*($an+$bd+$ad+$bn) if $op eq 'mod'; # Quotient/floor/product buffers.
   $self->_scratch_set($base,$floor+512+$accumulator+8*$digits);
   my $same=$an==$bn && $ad==$bd && JGraft::Util::_rational_same_magnitude($a,$b,$lib);
   if ($op eq 'add') {
      $size=$az?$blen:$bz?$alen:$same && $as!=$bs?1:$size;
   }
   elsif ($op eq 'sub') {
      $size=$bz?$alen:$az?$blen-$bs+($bs?0:1):$same && $as==$bs?1:$size;
   }
   elsif ($op eq 'mul') {
      $size=$az || $bz?1:$ao?$blen-$bs+$negative:$bo?$alen-$as+$negative:$size;
   }
   elsif ($op eq 'div') {
      $size=$az?1:$bo?$alen-$as+$negative:$same?1+$negative:$size;
   }
   else { $size=1 if $az || $same || ($ai && $bo) }
   # Padding covers small representation/header differences across Math versions.
   my $bytes=192+8*($size+8);
   if ($final) { $self->_reserve($size,$bytes,1) }
   else { $self->_scratch_set($base,$floor+512+$accumulator+8*$digits+$bytes) }
   my $result;
   if ($op eq 'add') { $result=$a+$b }
   elsif ($op eq 'sub') { $result=$a-$b }
   elsif ($op eq 'mul') { $result=$a*$b }
   elsif ($op eq 'div') { $result=$a/$b }
   else {
      my $quotient=$a/$b;
      require POSIX unless ref $quotient;
      my $floor=ref($quotient)?$quotient->bfloor:POSIX::floor($quotient);
      $result=$a-$floor*$b;
   }
   $workspace->[2]=$final?0:$bytes;
   return $result;
}
sub JGraft::Expr::ADD::_execute {
   my ($expr,$self,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $workspace=[$scratch_base,0];
   my $values=$self->_numeric_values($expr,$depth,$workspace);
   my $result=0;
   if (@$values && ref $values->[0]) {
      for my $i (0..$#$values) { $result=$self->_exact_step('add',$result,$values->[$i],$workspace,$i==$#$values) }
      $self->{scratch_mem}=$scratch_base+$workspace->[1];
      return $self->_finite_result($result);
   }
   $self->_tick(scalar @$values);
   $result+=$_ for @$values;
   return $self->_finite_result($result);
}
sub JGraft::Expr::MUL::_execute {
   my ($expr,$self,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $workspace=[$scratch_base,0];
   my $values=$self->_numeric_values($expr,$depth,$workspace);
   my $result=1;
   if (@$values && ref $values->[0]) {
      for my $i (0..$#$values) { $result=$self->_exact_step('mul',$result,$values->[$i],$workspace,$i==$#$values) }
      $self->{scratch_mem}=$scratch_base+$workspace->[1];
      return $self->_finite_result($result);
   }
   $self->_tick(scalar @$values);
   $result*=$_ for @$values;
   return $self->_finite_result($result);
}
sub JGraft::Expr::SUB::_execute {
   my ($expr,$self,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $workspace=[$scratch_base,0];
   my ($a,$b)=@{$self->_numeric_values($expr,$depth,$workspace)};
   if (ref $a) { return $self->_finite_result($self->_exact_step('sub',$a,$b,$workspace,1)) }
   $self->_tick(1);
   return $self->_finite_result($a-$b);
}
sub JGraft::Expr::DIV::_execute {
   my ($expr,$self,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $workspace=[$scratch_base,0];
   my ($a,$b)=@{$self->_numeric_values($expr,$depth,$workspace)};
   (ref($b)?!$b->is_zero:$b!=0) or $self->_fail('INVALID_TARGET','Division by zero');
   if (ref $a) { return $self->_finite_result($self->_exact_step('div',$a,$b,$workspace,1)) }
   $self->_tick(1);
   return $self->_finite_result($a/$b);
}
sub JGraft::Expr::MOD::_execute {
   my ($expr,$self,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   my $workspace=[$scratch_base,0];
   my ($a,$b)=@{$self->_numeric_values($expr,$depth,$workspace)};
   (ref($b)?!$b->is_zero:$b!=0) or $self->_fail('INVALID_TARGET','Division by zero');
   if (ref $a) { return $self->_finite_result($self->_exact_step('mod',$a,$b,$workspace,1)) }
   $self->_tick(1);
   require POSIX;
   my $quotient=$a/$b;
   my $floor=ref($quotient)?$quotient->bfloor:POSIX::floor($quotient);
   return $self->_finite_result($a-$floor*$b);
}

# POW/LOG validate domains at execution time, including literal operands in probes.
sub _power_values {
   my ($self,$expr,$field,$depth,$workspace)=@_;
   my $a=$self->_eval($expr->{base},$depth+1);
   my $b=$self->_input_value($expr,$field,$depth);
   for ($a,$b) {
      type_mask($_)==TYPE_NUMBER && is_finite($_)
         or $self->_fail('INVALID_TARGET','POW/LOG expects finite numbers');
   }
   if (ref($a) || ref($b)) {
      ($a,$b)=($self->_number($a,$workspace),$self->_number($b,$workspace));
   }
   return ($a,$b);
}
sub JGraft::Expr::POW::_execute {
   my ($expr,$self,$depth)=@_;
   my $base=$self->{scratch_mem};
   local $self->{scratch_mem}=$base;
   my $workspace=[$base,256];
   $self->_scratch_set(@$workspace);
   my ($a,$b)=$self->_power_values($expr,'exponent',$depth,$workspace);
   $a>=0 && ($a!=0 || $b>=0) or $self->_fail('INVALID_TARGET','Invalid POW domain');
   return 1 if $b==0 || $a==1;
   return 0 if $a==0;
   if (is_integer($b)) {
      $a=$self->_number($a,$workspace) unless ref $a;
      my $size=JGraft::Util::estimate_number_digits($a);
      my $exponent=abs(JGraft::Util::to_native_number($b));
      my $digits=($size+1)*$exponent+8;
      # Bound the result, intermediate products and exponentiation work before bpow.
      $self->_scratch_set($base,$workspace->[1]+512+32*$digits);
      $self->_reserve(1+$digits*$digits*.01,192+8*$digits,1);
      local ($Math::BigRat::accuracy,$Math::BigRat::precision);
      my $out=$a->bpow($b);
      is_finite($out) or $self->_fail('UNSUPPORTED_GRAFT','POW outside supported range');
      return $out;
   }
   my $out;
   if (ref $a) {
      my $size=JGraft::Util::estimate_number_digits($a)+JGraft::Util::estimate_number_digits($b);
      my ($n,$d)=JGraft::Util::_rational_shape($a,ref($a)->config('lib'));
      my $precision=40+($n<$d?$n:$d);
      $self->_scratch_set($base,$workspace->[1]+1024+128*($size+$precision));
      $self->_reserve(1+$size*$precision,$precision*8+192,1);
      local ($Math::BigFloat::accuracy,$Math::BigFloat::precision);
      $out=0+$a->as_float($precision)->bpow($b->as_float($precision),$precision)->numify;
   }
   else { $self->_tick(1); $out=$a**$b }
   is_finite($out) && $out!=0 or $self->_fail('UNSUPPORTED_GRAFT','POW overflow or underflow');
   return $out;
}
sub JGraft::Expr::LOG::_execute {
   my ($expr,$self,$depth)=@_;
   my $base=$self->{scratch_mem};
   local $self->{scratch_mem}=$base;
   my $workspace=[$base,256];
   $self->_scratch_set(@$workspace);
   my ($a,$b)=$self->_power_values($expr,'value',$depth,$workspace);
   $a>0 && $a!=1 && $b>0 or $self->_fail('INVALID_TARGET','Invalid LOG domain');
   return 0 if $b==1;
   return 1 if $a==$b;
   my $out;
   if (ref $a) {
      my $size=JGraft::Util::estimate_number_digits($a)+JGraft::Util::estimate_number_digits($b);
      my $lib=ref($a)->config('lib');
      my ($an,$ad)=JGraft::Util::_rational_shape($a,$lib);
      my ($bn,$bd)=JGraft::Util::_rational_shape($b,$lib);
      my $ap=$an<$ad?$an:$ad;
      my $bp=$bn<$bd?$bn:$bd;
      my $precision=40+($ap>$bp?$ap:$bp);
      $self->_scratch_set($base,$workspace->[1]+1024+128*($size+$precision));
      $self->_reserve(1+$size*$precision*.1,$precision*8+192,1);
      local ($Math::BigFloat::accuracy,$Math::BigFloat::precision);
      # Extra digits preserve a base arbitrarily close to one before taking log.
      my $la=$a->as_float($precision)->blog(undef,$precision);
      my $lb=$b->as_float($precision)->blog(undef,$precision);
      $la->is_zero and $self->_fail('UNSUPPORTED_GRAFT','LOG base outside supported precision');
      $out=$lb->bdiv($la,$precision)->numify;
      $out=0+$out;
   }
   else { $self->_tick(1); $out=log($b)/log($a) }
   is_finite($out) && $out!=0 or $self->_fail('UNSUPPORTED_GRAFT','LOG overflow or underflow');
   return $out;
}

sub _round_choice {
   my ($self,$v,$names)=@_;
   my $type=type_mask($v);
   if ($type==TYPE_STRING) {
      $self->_tick(length($v));
      for my $i (0..$#$names) { return $i if $v eq $names->[$i] }
   }
   elsif ($type==TYPE_NUMBER && is_integer($v) && $v>=0 && $v<@$names) {
      return JGraft::Util::to_native_number($v);
   }
   $self->_fail('INVALID_OPERAND','Invalid ROUND mode or output format');
}
sub _round_integer {
   my ($self,$v,$workspace)=@_;
   is_integer($v) or $self->_fail('INVALID_OPERAND','ROUND position must be an integer');
   my $r=$self->_number($v,$workspace);
   return $r->numerator;
}
# Decimal values are a sign, a compact coefficient, and a base-ten exponent.
# All exponent arithmetic stays exact; only bounded string indices become native.
sub JGraft::Expr::ROUND::_execute {
   my ($expr,$self,$depth)=@_;
   my $base=$self->{scratch_mem};
   local $self->{scratch_mem}=$base;
   my $workspace=[$base,1024];
   $self->_scratch_set(@$workspace);
   require Math::BigInt;
   local ($Math::BigInt::accuracy,$Math::BigInt::precision,
      $Math::BigRat::accuracy,$Math::BigRat::precision);
   my ($mode,$as,$at,$shift)=(1,undef,Math::BigInt->new(0),Math::BigInt->new(0));
   if (exists $expr->{options}) {
      my $opt=$self->_eval($expr->{options},$depth+1);
      if (type_mask($opt)==TYPE_NUMBER) { $shift=$self->_round_integer($opt,$workspace) }
      elsif (ref($opt) eq 'HASH') {
         $mode=$self->_round_choice($opt->{mode},[qw(DOWN HALF_UP HALF_EVEN CEILING FLOOR UP)]) if exists $opt->{mode};
         $as=$self->_round_choice($opt->{as},[qw(NUM INT STR SIG)]) if exists $opt->{as};
         $at=$self->_round_integer($opt->{at},$workspace) if exists $opt->{at};
         $shift=$self->_round_integer($opt->{shift},$workspace) if exists $opt->{shift};
      }
      else { $self->_fail('INVALID_OPERAND','ROUND options must be an integer or object') }
   }
   my $v=$self->_input_value($expr,'value_expr',$depth);
   my $type=type_mask($v);
   $type==TYPE_STRING || ($type==TYPE_NUMBER && is_finite($v))
      or $self->_fail('INVALID_TARGET','ROUND expects a finite number or decimal string');
   $as=$type==TYPE_STRING?2:0 unless defined $as;
   my $text;
   if ($type==TYPE_STRING) {
      $workspace->[1]+=32*length($v);
      $self->_scratch_set(@$workspace);
      $text="$v";
   }
   elsif (ref $v) {
      my ($compact,$expanded)=JGraft::Util::_number_sizes($v);
      my $size=$v->isa('Math::BigRat')?$expanded:$compact;
      $workspace->[1]+=512+256*$size;
      $self->_scratch_set(@$workspace);
      $self->_tick(1+$size*$size);
      $text=eval { $v->isa('JGraft::JSON::Number')?$v->token
         :$v->isa('Math::BigFloat')?$v->bsstr:JGraft::Util::to_decimal_string($v,0) };
      my $error=$@;
      die $error if ref $error;
      $self->_fail('UNSUPPORTED_GRAFT',"ROUND decimal conversion: $error") if $error;
   }
   else { $text=$v?"$v":sprintf('%g',$v) }
   my $size=length($text);
   $workspace->[1]+=512+32*$size;
   $self->_scratch_set(@$workspace);
   $self->_tick(1+$size);
   $text =~ /\A([+-]?)(0|[1-9][0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?\z/
      or $self->_fail('INVALID_TARGET','Invalid ROUND decimal input');
   my ($sign,$whole,$fraction,$exponent)=($1,$2,defined($3)?$3:'',defined($4)?$4:'0');
   $sign=$sign eq '-'?'-':'';
   my $digits=$whole.$fraction;
   my $e=Math::BigInt->new($exponent)->badd($shift)->bsub(length($fraction));
   my $precision=$e->copy;
   # Whole-number trailing zeros do not establish significant precision.
   if (!length $fraction) {
      my ($zeros)=$digits =~ /(0*)\z/;
      $precision->badd(length($zeros)) if $digits =~ /[1-9]/;
   }
   my $place=$at->copy->bneg;
   $precision=$place->copy if $precision<$place;
   $digits =~ s/^0+//;
   $digits='0' unless length $digits;
   my $cut=$place-$e;
   if ($cut>0 && $digits ne '0') {
      my ($kept,$discard,$half)=('0',1,-1);
      if ($cut<=length($digits)) {
         my $n=$cut->numify;
         my $tail=substr($digits,length($digits)-$n);
         $kept=substr($digits,0,length($digits)-$n) || '0';
         $discard=$tail =~ /[1-9]/?1:0;
         my $first=ord(substr($tail,0,1))-48;
         $half=$first<5?-1:$first>5?1:substr($tail,1)=~/[1-9]/?1:0;
      }
      my $up=$discard && ($mode==5 || ($mode==3 && !$sign) || ($mode==4 && $sign)
         || ($mode==1 && $half>=0) || ($mode==2 && ($half>0 || (!$half && substr($kept,-1)%2))));
      if ($up) {
         # String carry avoids native numeric coercion of long coefficients.
         my $i=length($kept)-1;
         while ($i>=0 && substr($kept,$i,1) eq '9') { substr($kept,$i--,1)='0' }
         if ($i<0) { $kept='1'.$kept }
         else { substr($kept,$i,1)=chr(ord(substr($kept,$i,1))+1) }
      }
      ($digits,$e)=($kept,$place->copy);
   }
   if ($digits ne '0') {
      $digits =~ s/(0+)\z// and $e->badd(length($1));
   }
   else { $e=Math::BigInt->new(0) }
   if ($as==0) {
      my $out=0+($sign.$digits.'e'.$e->bstr);
      is_finite($out) && ($out!=0 || $digits eq '0')
         or $self->_fail('UNSUPPORTED_GRAFT','ROUND number overflow or underflow');
      return $out;
   }
   if ($as==1) {
      $digits eq '0' || $e>=0 or $self->_fail('INVALID_TARGET','ROUND INT result is fractional');
      return 0 if $digits eq '0';
      my $length=length($digits)+$e->numify;
      $self->_scratch_set($base,$workspace->[1]+512+16*$length);
      $self->_reserve(1+$length*$length*.01,192+8*$length,1);
      return Math::BigInt->new($sign.$digits)->bmul(Math::BigInt->new(10)->bpow($e));
   }
   # SIG can remain compact at any exponent. Plain decimals are used when they
   # express the requested precision without trailing whole-number zeroes.
   my $top=$digits eq '0'?$precision->copy:$e+length($digits)-1;
   my $scientific=$as==3 && ($precision>0 || $top< -6
      || ($precision==0 && $digits ne '0' && $e>0));
   my $p=$as==2?$place:$precision;
   if ($scientific) {
      my $count=$top-$p+1;
      my $length=$count->numify+length($top->bstr)+4;
      $self->_reserve($length,$length,0);
      $self->_scratch_set($base,$workspace->[1]+2*$length);
      my $out=$digits.('0'x($count->numify-length($digits)));
      substr($out,1,0)='.' if length($out)>1;
      return $sign.$out.'e'.$top->bstr;
   }
   my $point=$digits eq '0'?1:length($digits)+$e->numify;
   my $places=$p<0?(-$p)->numify:0;
   my $length=($point>0?$point:1)+($places?1+$places:0)+length($sign);
   $self->_reserve($length,$length,0);
   $self->_scratch_set($base,$workspace->[1]+3*$length);
   my $out;
   if ($point<=0) { $out='0.'.('0'x(-$point)).$digits }
   elsif ($point>=length($digits)) { $out=$digits.('0'x($point-length($digits))) }
   else { $out=substr($digits,0,$point).'.'.substr($digits,$point) }
   if ($places) {
      $out.='.' unless $out =~ /\./;
      my $have=length($out)-index($out,'.')-1;
      $out.='0'x($places-$have) if $places>$have;
   }
   return $sign.$out;
}


sub _slice {
   my ($self,$expr,$depth)= @_;
   my $scratch_base=$self->{scratch_mem};
   local $self->{scratch_mem}=$scratch_base;
   local $self->{path_workspace}=[$scratch_base,0];
   my ($value,$ofs,$len,$lim);
   if (exists $expr->{config_obj}) {
      my $config=$self->_eval($expr->{config_obj},$depth+1);
      ref $config eq 'HASH' or $self->_fail('INVALID_OPERAND','SLICE config must be an object');
      for my $key (qw(ofs len lim)) {
         next unless exists $config->{$key};
         is_integer($config->{$key}) && $config->{$key}>=0 or $self->_fail('INVALID_OPERAND','Invalid SLICE bound');
      }
      if (exists $config->{path}) {
         ref $config->{path} eq 'ARRAY' or $self->_fail('INVALID_OPERAND','SLICE path must be an array');
         require JGraft;
         $value=$self->_read_value($self->_expand_path(JGraft::NODE($config->{path}),'read',$depth+1));
      }
      else { $value=$self->_read_value($self->{current}) }
      ($ofs,$len,$lim)=@{$config}{qw(ofs len lim)};
      if (grep ref($_),($ofs,$len,$lim)) {
         ($ofs,$len,$lim)=map ref($_)?$self->_number($_,$self->{path_workspace}):$_,($ofs,$len,$lim);
      }
      if (defined $ofs && defined $len && defined $lim && $ofs+$len!=$lim) { $self->_fail('INVALID_OPERAND','Inconsistent SLICE bounds') }
      $ofs=defined $len && defined $lim? $lim-$len : 0 unless defined $ofs;
   }
   else {
      $value=$self->_eval($expr->{value_expr},$depth+1);
      $ofs=$self->_eval($expr->{ofs},$depth+1);
      $len=$self->_eval($expr->{len},$depth+1) if exists $expr->{len};
      is_integer($ofs) && (!exists $expr->{len} || is_integer($len)) or $self->_fail('INVALID_OPERAND','SLICE bounds must be integers');
      ($ofs,$len)=map ref($_)?$self->_number($_,$self->{path_workspace}):$_,($ofs,$len) if ref($ofs) || ref($len);
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
   if ($type==TYPE_STRING) { $self->_tick(($lim-$ofs)*.001); $self->_reserve(0,4*($lim-$ofs),0); return substr($value,$ofs,$lim-$ofs) }
   my $out=$self->_alloc_array($lim-$ofs);
   $self->_append_range($out,$value,$ofs,$lim-$ofs);
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
POW uses exact rational exponentiation for integer exponents, including integer
results beyond native floating point precision. Fractional exponents return native
floating point; exact numeric operands retain decimal precision during calculation.
Results outside native range fail with C<UNSUPPORTED_GRAFT>.
LOG accepts exact numeric operands, preserving bases close
to one during logarithm calculation, and returns a native floating point result.
Both reject nonfinite inputs with C<INVALID_TARGET>; overflow and nonzero results
that underflow to zero fail with C<UNSUPPORTED_GRAFT>.

ROUND implements all six decimal rounding modes and the C<NUM>, C<INT>, C<STR>,
and C<SIG> output formats. C<INT> can return Math::BigInt without precision loss;
C<NUM> uses native numeric storage and fails on overflow or nonzero underflow.
String rounding and significant-digit formatting operate on compact coefficients
and exact exponents, without expanding the input's exponent first. Numeric input
uses its CASTSTR decimal representation; rationals without a finite decimal
representation fail with C<UNSUPPORTED_GRAFT>, as for CASTSTR. Numeric objects
and caller-supplied Math precision settings remain unchanged.
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
Ownership, paid capacity, date summaries, split metadata, and pending edits share
guarded container records with weak owners and per-application serial identities.
Lazy undo retains separate weak serial/origin identities. Split metadata does not
retain its array, and only an active MOVE batch retains deferred arrays strongly.
Application namespaces and caches are released on success, failure, and callback
exceptions, while public results and lazy undo state remain available.

=constructor new

Options: C<jgraft>, optional C<input>, C<clone>, C<undo>, C<limits>,
C<codepoint_policy>, and C<date_format>. Limits
are estimated cumulative C<ops>, C<mem>, C<new_obj>, and maximum C<depth>. Defaults
are 1,000,000 operations, 64 MiB, 100,000 data containers, and depth 256. An explicit
undef disables an individual limit. Memory accounting is a conservative cumulative
allocation estimate; it does not subtract reclaimed retained storage. Unicode
validation, path and inspection vectors, temporary packed views, sequence workspaces,
character-class construction,
JOIN/collection work vectors, SPLICE buffers, and deferred MOVE queues use scoped
scratch reservations instead of accumulating in C<mem>. Explicit reservations,
including small buffers held across tracked calls, must fit in full alongside
cumulative memory and other active reservations; a scratch failure can leave
C<mem> below its limit.
Returned captures, completed caches, and execution metadata remain cumulative.
Private match state is scoped scratch; matching returns only its completed
capture table. Direct-element SPLIT provenance stays reserved through its
consuming COPY, MOVE, literal-array insertion, or SPLICE. SPLICE covers all
replacement provenance records together. Metadata copy/slice/filter/append
vectors are scratch, while installed row vectors and formatting rows remain
retained. Exact-JSON encoding and formatting walk live member links without
allocating offset lists; their traversal work remains charged.
Codepoint-policy callback context values are retained allocations because the
callback can keep them. Temporary rational operands and numeric bound copies are
scoped scratch but still contribute to C<new_obj>. Arithmetic operand vectors and
decimal-formatting workspaces stay reserved through their consuming operation.
Escaping arithmetic results remain retained; numeric CASTSTR reserves a
conservative output-size bound before expanding an exact decimal string.
Object transformation key lists, date-export memo/key tables, and resolved
SPLIT/JOIN configurations are scoped scratch. Date normalization and formatter
cache entries remain cumulative metadata. Date export chooses exact-object
storage directly, preserving hidden duplicate members without a discarded hash.
Creating an exact-number lazy cache is a retained allocation; an existing cache
is pre-existing input storage. Numeric and exact-object accounting contexts are
localized per application and suspended during lazy undo construction.
Numeric inspection, clone sizing, and arithmetic bounds use representation digit
counts instead of allocating decimal spellings. Exact arithmetic reserves work
and simultaneous temporary growth before each operation; its final result is
charged as retained memory before calculation using a conservative digit bound.
Intermediate accumulators remain scoped scratch. Native arithmetic charges its
fold work before execution. Numeric clones charge their
digit-copy work. Plain hash construction can initialize from an existing table,
reserving its temporary key/value list through allocation and copying; namespaces
and capture-table copies share this path. LOCAL bindings use paid property growth.
Constructed containers reserve logical capacity; filling paid slots or reusing
them after a shrink does not charge the slots again. Ownership records use weak
references and contribute to retained memory estimates.
Input and pre-existing graft containers are excluded
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
