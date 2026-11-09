package JGraft::_Sequence;
# VERSION
# ABSTRACT: Array and string successors and observable capture selection
use strict;
use warnings;
no warnings 'recursion';
use Scalar::Util qw(blessed refaddr);
use JGraft::Util qw(:types type_mask is_expr is_integer);

# The caller owns [scratch base, simultaneous bytes] through matching, including
# any subject view sharing that call. Helpers share this reservation so returned
# frontiers stay covered until their consumer discards or replaces them.
sub _new {
   my ($class,$match,$value,$cursor,$offset,$exact,$suffix,$workspace)=@_;
   $match->{exec}->_tick(scalar keys %{$match->{reserved} || {}});
   $workspace->[1]+=160+64*keys %{$match->{reserved} || {}};
   $match->{exec}->_scratch_set(@$workspace);
   return bless {match=>$match,exec=>$match->{exec},value=>$value,parent=>$cursor,
      offset=>$offset,exact=>$exact,suffix=>$suffix,workspace=>$workspace,
      string=>blessed($value) && $value->isa('JGraft::CodepointArray'),groups=>[],reserved=>{%{$match->{reserved} || {}}}},$class;
}
sub _scratch {
   my ($self,$bytes)=@_;
   my $workspace=$self->{workspace};
   $workspace->[1]+=$bytes;
   $self->{exec}->_scratch_set(@$workspace);
}
# Loop boundaries know which vectors are still live. Keep a floor for their
# caller's workspace, then replace only this loop's completed exploration.
# No container lifecycle or reference-count tracking is needed.
sub _prune {
   my ($self,$floor,$bytes)=@_;
   my $workspace=$self->{workspace};
   $workspace->[1]=$floor+$bytes;
   my $active=$workspace->[0]+$workspace->[1];
   if ($active<=$self->{exec}{scratch_mem}) {
      $self->{exec}{scratch_mem}=$active;
   }
   else { $self->{exec}->_scratch_set(@$workspace) }
}
sub _vector_bytes {
   my ($self,$states)=@_;
   $self->{exec}->_tick(scalar @$states);
   my $bytes=80+16*@$states;
   $bytes+=$_->{bytes} for @$states;
   return $bytes;
}
sub _size { $_[0]{string}? $_[0]{value}->size : scalar @{$_[0]{value}} }
sub _present { $_[0]{string}? $_[1]<$_[0]->_size : $_[0]{exec}->_present($_[0]{value},$_[1]) }
sub _cursor {
   my ($self,$position)=@_;
   my $value=$self->{value};
   my $exists=$self->_present($position);
   my $cursor=$self->{match}->_cursor($exists? ($self->{string}? $value->at($position) : $value->[$position]) : undef,$exists,$position,
      [$self->{parent}{path},$position],$self->{parent}{anchored});
   $cursor->{$self->{string}? 'string' : 'array'}=$value;
   return $cursor;
}
sub _state {
   my ($self,$position,$caps,$prefs,$sub,$seen)=@_;
   $self->{exec}->_tick(1);
   my $bytes=128+80*@$prefs+16*@$sub;
   $self->_scratch($bytes+16);
   return {pos=>$position,caps=>$caps,prefs=>$prefs,sub=>$sub,seen=>$seen || 0,bytes=>$bytes};
}
sub _with {
   my ($self,$expr,$depth,$callback)=@_;
   my $exec=$self->{exec};
   my $temp=$exec->_copy_hash($exec->{temp}[0]);
   local $exec->{temp}=[$temp,1];
   $exec->_tick(scalar @{$expr->bindings});
   for my $pair (@{$expr->bindings}) {
      my $key=$pair->[0]; $key="$key";
      $exec->_set_member($temp,$key,$exec->_eval($pair->[1],$depth+1));
   }
   return $callback->();
}

# Root declarations are inspected before exploring endpoints. Names are evaluated
# with NODE missing, but the declaration's lexical TEMP overlay remains visible.
sub _root {
   my ($self,$spec,$depth)=@_;
   my $exec=$self->{exec};
   $exec->_enter($depth);
   return unless is_expr($spec);
   my $name=$spec->name;
   local $exec->{expression}=$spec;
   return $self->_root($exec->_macro($spec,$depth+1),$depth+1) if $name eq 'EXPR';
   return $self->_with($spec,$depth,sub { $self->_root($spec->match_expr,$depth+1) }) if $name eq 'WITH';
   return $self->_root($spec->match_spec,$depth+1)
      if ($name eq 'HAS' || $name eq 'IS') && !exists $spec->{value_expr};
   return unless $name eq 'SEQ' || $name eq 'SEQMIN' || $name eq 'SEQMAX';
   my $group={mode=>$name,node=>$spec};
   if ($name ne 'SEQ' && $self->{match}{observable} && !$self->{match}{suppress_captures}) {
      local $exec->{current}=[[undef,0],[]];
      local $exec->{match_cursor};
      my $key=$exec->_eval($spec->capture_name,$depth+1);
      my $type=type_mask($key);
      $type==TYPE_NULL || $type==TYPE_STRING || ($type==TYPE_NUMBER && is_integer($key))
         or $exec->_fail('INVALID_OPERAND','Invalid sequence capture name');
      $group->{preference}=$name eq 'SEQMAX'? -1 : 1;
      if (defined $key) {
         $key="$key";
         !exists($self->{reserved}{$key}) && !exists($self->{match}{captures}{$key})
            or $exec->_fail('INVALID_OPERAND','Duplicate capture name');
         $self->_scratch(64+4*length($key));
         $self->{reserved}{$key}=1;
         $group->{name}=$key;
      }
   }
   return $group;
}
sub _prepare {
   my ($self,$specs,$depth)=@_;
   my $exec=$self->{exec};
   my $found=0;
   $self->{slots}=0;
   $exec->_tick(scalar @$specs);
   $self->_scratch(64*@$specs);
   $self->_scratch(160); # One preparation cursor reused across declarations.
   for my $i (0..$#$specs) {
      unless ($self->_potential($specs->[$i],{},$depth+1)) {
         push @{$self->{groups}},undef;
         next;
      }
      if ($self->_deferred($specs->[$i],{})) {
         my $group={deferred=>1};
         $group->{slot}=$self->{slots}++ if $self->{match}{observable} && !$self->{match}{suppress_captures};
         push @{$self->{groups}},$group;
         $self->{deferred}=1; $found=1;
         next;
      }
      my $position=$self->{offset}+$i;
      $position=$self->_size if $position>$self->_size;
      my $cursor=$self->_cursor($position);
      local $exec->{current}=[[$cursor->{value},$cursor->{exists}],[]];
      local $exec->{match_cursor}=$cursor;
      my $group=$self->_root($specs->[$i],$depth+1);
      $group->{slot}=$self->{slots}++ if $group && $self->{match}{observable} && !$self->{match}{suppress_captures};
      push @{$self->{groups}},$group;
      $found=1 if $group;
   }
   return $found;
}

sub _deferred {
   my ($self,$spec,$active)=@_;
   $self->{exec}->_tick(1);
   return 0 unless is_expr($spec);
   my $id=refaddr($spec);
   return 0 if $active->{$id};
   local $active->{$id}=1;
   my $name=$spec->name;
   if ($name eq 'EXPR') {
      return 1 if is_expr($spec->expr_name);
      my $key=$spec->expr_name; $key="$key";
      return exists($self->{exec}{expr}[0]{$key}) && $self->_deferred($self->{exec}{expr}[0]{$key},$active);
   }
   return 1 if $name eq 'WITH';
   return $self->_deferred($spec->match_spec,$active)
      if ($name eq 'HAS' || $name eq 'IS') && !exists $spec->{value_expr};
   return 0;
}

# Do not evaluate unrelated WITH bindings or recursive value macros merely to
# discover whether an array has sequence roots. Runtime expansion remains in
# _root/_successors, where NODE and lexical bindings are available.
sub _potential {
   my ($self,$spec,$active,$depth)=@_;
   $self->{exec}->_enter($depth);
   return 0 unless is_expr($spec);
   my $id=refaddr($spec);
   return 0 if $active->{$id};
   local $active->{$id}=1;
   my $name=$spec->name;
   return 1 if $name eq 'SEQ' || $name eq 'SEQMIN' || $name eq 'SEQMAX';
   return $self->_potential($spec->match_expr,$active,$depth+1) if $name eq 'WITH';
   return $self->_potential($spec->match_spec,$active,$depth+1)
      if ($name eq 'HAS' || $name eq 'IS') && !exists $spec->{value_expr};
   if ($name eq 'EXPR') {
      return 1 if is_expr($spec->expr_name);
      my $key=$spec->expr_name; $key="$key";
      return 0 unless exists $self->{exec}{expr}[0]{$key};
      return $self->_potential($self->{exec}{expr}[0]{$key},$active,$depth+1);
   }
   return 0;
}

sub _kind_at {
   my ($self,$spec,$depth)=@_;
   $self->{exec}->_enter($depth);
   return 0 unless is_expr($spec);
   my $name=$spec->name;
   return 1 if $name eq 'SEQ' || $name eq 'SEQMIN' || $name eq 'SEQMAX';
   return $self->_kind_at($self->{exec}->_macro($spec,$depth+1),$depth+1) if $name eq 'EXPR';
   return $self->_with($spec,$depth,sub { $self->_kind_at($spec->match_expr,$depth+1) }) if $name eq 'WITH';
   return $self->_kind_at($spec->match_spec,$depth+1)
      if ($name eq 'HAS' || $name eq 'IS') && !exists $spec->{value_expr};
   return 0;
}

# A computed EXPR name can select an ordinary expression instead of a sequence
# root. Accept ordinary element semantics only when no root actually expands to
# a sequence in that interpretation.
sub _ordinary {
   my ($self,$specs,$depth)=@_;
   my $exec=$self->{exec};
   $self->_scratch(160); # One reused cursor and linked path element.
   local $self->{match}{sequence}=undef;
   my $size=$self->_size;
   my $end=$self->{offset}+@$specs;
   return 0 if $end>$size+1;
   if ($end<$size && ($self->{exact} || $self->{suffix})) {
      $exec->_tick($size-$end);
      for my $i ($end..$size-1) {
         my $present=$self->_present($i);
         return 0 if $self->{exact}? $present : !$present;
      }
   }
   $exec->_tick(scalar @$specs);
   for my $i (0..$#$specs) {
      my $cursor=$self->_cursor($self->{offset}+$i);
      {
         local $exec->{current}=[[$cursor->{value},$cursor->{exists}],[]];
         local $exec->{match_cursor}=$cursor;
         my ($result,$ok,$error,$code,$message,$diagnostic,$fatal);
         {
            local $exec->{error}=$exec->{error};
            local $exec->{message}=$exec->{message};
            local $exec->{diagnostic}=$exec->{diagnostic};
            $ok=eval { $result=$self->_kind_at($specs->[$i],$depth+1); 1 };
            $error=$@;
            unless ($ok) {
               my $own=blessed($error) && refaddr($error)==refaddr($exec);
               ($code,$message,$diagnostic)=@$exec{qw(error message diagnostic)} if $own;
               if ($own && defined($code) && ($code eq 'INVALID_TARGET' || $code eq 'INVALID_OPERAND')) { $result=0 }
               else { $fatal=1 }
            }
         }
         if ($fatal) {
            @$exec{qw(error message diagnostic)}=($code,$message,$diagnostic) if defined $code;
            die $error;
         }
         return 0 if $result;
      }
      return 0 unless $self->{match}->_test($specs->[$i],$cursor,$depth+1,0);
   }
   return 1;
}

# All length preferences precede all starting-position preferences; nested array
# preferences are resolved there and do not rank placements in this array.
sub _better {
   my ($self,$a,$b)=@_;
   return 1 unless $b;
   my $n=@{$a->{prefs}};
   $self->{exec}->_tick(2*$n+@{$a->{sub}}+1);
   for my $column (0,1) {
      for my $i (0..$n-1) {
         my $av=$a->{prefs}[$i][$column];
         my $bv=$b->{prefs}[$i][$column];
         return $av<$bv if $av!=$bv;
      }
   }
   for my $i (0..$#{$a->{sub}}) {
      last if $i>@{$b->{sub}}-1;
      return $a->{sub}[$i]<$b->{sub}[$i] if $a->{sub}[$i]!=$b->{sub}[$i];
   }
   return 0;
}
sub _unique {
   my ($self,$states)=@_;
   $self->{exec}->_tick(scalar @$states);
   return $states if @$states<2;
   $self->_scratch(208+80*@$states); # Endpoint hash and returned vector.
   my %best;
   for my $state (@$states) {
      my $key=0+$state->{pos};
      $best{$key}=$state if $self->_better($state,$best{$key});
   }
   return [values %best];
}
sub _walk {
   my ($self,$specs,$states,$depth)=@_;
   $self->{exec}->_tick(scalar @$specs);
   my $floor=$self->{workspace}[1];
   for my $spec (@$specs) {
      my $live=$self->_vector_bytes($states);
      $self->_prune($floor,$live+80);
      my @next;
      my $next_bytes=0;
      my $visited=0;
      $self->{exec}->_tick(scalar @$states);
      for my $state (@$states) {
         $self->_prune($floor,$live+80+$next_bytes) if $visited++;
         my $found=$self->_successors($spec,$state,$depth+1,0,undef);
         $self->_scratch(16*@$found);
         $next_bytes+=$self->_vector_bytes($found)-80;
         push @next,@$found;
      }
      $states=$self->_unique(\@next);
      last unless @$states;
   }
   return $states;
}
sub _array {
   my ($self,$specs,$depth)=@_;
   my $match=$self->{match};
   local $match->{reserved}=$self->{reserved};
   local $match->{sequence}=$self;
   $self->{exec}->_tick($self->{slots});
   $self->_scratch(64*$self->{slots});
   my $floor=$self->{workspace}[1];
   $self->_scratch(80);
   my $states=[$self->_state($self->{offset},$match->{captures},[map [0,0],1..$self->{slots}],[])];
   $self->{exec}->_tick(scalar @$specs);
   for my $i (0..$#$specs) {
      my $live=$self->_vector_bytes($states);
      $self->_prune($floor,$live+80);
      my @next;
      my $next_bytes=0;
      my $visited=0;
      $self->{exec}->_tick(scalar @$states);
      for my $state (@$states) {
         $self->_prune($floor,$live+80+$next_bytes) if $visited++;
         my $found=$self->_successors($specs->[$i],$state,$depth+1,1,$self->{groups}[$i]);
         $self->_scratch(16*@$found);
         $next_bytes+=$self->_vector_bytes($found)-80;
         push @next,@$found;
      }
      $states=$self->_unique(\@next);
      return $self->{deferred}? $self->_ordinary($specs,$depth) : 0 unless @$states;
   }
   my $best;
   $self->{exec}->_tick(scalar @$states);
   for my $state (@$states) {
      next unless $state->{seen};
      next if $self->{exact} && $state->{pos}!=$self->_size;
      if ($self->{suffix}) {
         my $present=1;
         $self->{exec}->_tick($self->_size-$state->{pos});
         for my $i ($state->{pos}..($self->_size-1)) {
            $present=0 unless $self->_present($i);
         }
         next unless $present;
      }
      $best=$state if $self->_better($state,$best);
   }
   return $self->{deferred}? $self->_ordinary($specs,$depth) : 0 unless $best;
   $match->{captures}=$best->{caps};
   return 1;
}

# STR searches starts left to right; a nested function match uses just its
# current character position. Capture preferences resolve over all endpoints.
sub _regex {
   my ($self,$spec,$depth,$position)=@_;
   my $match=$self->{match};
   local $match->{reserved}=$self->{reserved};
   local $match->{sequence}=$self;
   $self->_prepare([$spec],$depth+1);
   $self->_scratch(64*$self->{slots});
   my $last=defined($position)? $position : $self->_size;
   my $start=defined($position)? $position : 0;
   my $floor=$self->{workspace}[1];
   for (my $i=$start;$i<=$last;++$i) {
      $self->_prune($floor,0);
      my $state=$self->_state($i,$match->{captures},[map [0,0],1..$self->{slots}],[]);
      my $states=$self->_successors($spec,$state,$depth+1,1,$self->{groups}[0]);
      my $best;
      $self->{exec}->_tick(scalar @$states);
      for my $candidate (@$states) { $best=$candidate if $self->_better($candidate,$best) }
      if ($best) { $match->{captures}=$best->{caps}; return 1 }
   }
   return 0;
}
sub _text {
   my ($self,$spec,$state,$depth)=@_;
   my $exec=$self->{exec};
   my $type=type_mask($spec);
   my $size;
   if ($type==TYPE_STRING) {
      $size=$self->{value}->_literal($exec,$spec,$state->{pos});
   }
   elsif ($type==TYPE_NUMBER && is_integer($spec) && $spec>=0 && $spec<=0x10ffff) {
      $size=1 if $self->_present($state->{pos}) && $self->{value}->at($state->{pos})==$spec;
   }
   else { $exec->_fail('INVALID_OPERAND','Regex literal must be a string or Unicode codepoint') }
   return [] unless defined $size;
   return [$self->_state($state->{pos}+$size,$state->{caps},$state->{prefs},$state->{sub},$state->{seen})];
}

# Anchored matching for SPLIT separators and whole-field/trim assertions.
# There are no observable captures here; retain every endpoint until selecting
# the longest one, optionally requiring the end of a bounded character view.
sub _span {
   my ($self,$spec,$depth,$position,$end)=@_;
   my $match=$self->{match};
   local $match->{reserved}=$self->{reserved};
   local $match->{sequence}=$self;
   $self->_prepare([$spec],$depth+1);
   my $state=$self->_state($position,$match->{captures},[],[]);
   my $states=$self->_successors($spec,$state,$depth+1,1,$self->{groups}[0]);
   my $best;
   $self->{exec}->_tick(scalar @$states);
   for my $candidate (@$states) {
      next if defined($end) && $candidate->{pos}!=$end;
      $best=$candidate->{pos} if !defined($best) || $candidate->{pos}>$best;
   }
   return defined($best)? $best-$position : undef;
}

sub _successors {
   my ($self,$spec,$state,$depth,$root,$group)=@_;
   my $exec=$self->{exec};
   $exec->_enter($depth);
   $self->_scratch(256); # Cursor/path plus a result vector, including aliases.
   my $cursor=$self->_cursor($state->{pos});
   local $exec->{expression}=is_expr($spec)? $spec : $exec->{expression};
   local $exec->{current}=[[$cursor->{value},$cursor->{exists}],[]];
   local $exec->{match_cursor}=$cursor;
   local $self->{match}{captures}=$state->{caps};
   my ($result,$ok,$error,$code,$message,$diagnostic,$fatal);
   {
      local $exec->{error}=$exec->{error};
      local $exec->{message}=$exec->{message};
      local $exec->{diagnostic}=$exec->{diagnostic};
      local $self->{workspace}[0]=$exec->{scratch_mem}-$self->{workspace}[1];
      $ok=eval { $result=$self->_dispatch($spec,$state,$cursor,$depth,$root,$group); 1 };
      $error=$@;
      unless ($ok) {
         my $own=blessed($error) && refaddr($error)==refaddr($exec);
         ($code,$message,$diagnostic)=@$exec{qw(error message diagnostic)} if $own;
         if ($own && defined($code) && ($code eq 'INVALID_TARGET' || $code eq 'INVALID_OPERAND')) { $result=0 }
         else { $fatal=1 }
      }
   }
   if ($fatal) {
      @$exec{qw(error message diagnostic)}=($code,$message,$diagnostic) if defined $code;
      die $error;
   }

   # Nested calls can restore their entry reservation before arena growth.
   # Reinstall the checked arena size so returned frontiers stay covered.
   $exec->{scratch_mem}=$self->{workspace}[0]+$self->{workspace}[1];
   return $result || [];
}
sub _dispatch {
   my ($self,$spec,$state,$cursor,$depth,$root,$group)=@_;
   my $exec=$self->{exec};
   my $match=$self->{match};
   my $name=is_expr($spec)? $spec->name : '';
   return $self->_text($spec,$state,$depth) if $self->{string} && !is_expr($spec);
   if ($name eq 'EXPR') {
      my $body=$exec->_macro($spec,$depth+1);
      return $self->_successors($body,$state,$depth+1,$root,$group)
         if is_expr($body) && ($body->is_match || $body->name eq 'EXPR');
      return $self->{string}? $self->_text($exec->_eval($body,$depth+1),$state,$depth)
         : $self->_element($exec->_eval($body,$depth+1),$state,$cursor,$depth,1);
   }
   if ($name eq 'WITH') {
      return $self->_with($spec,$depth,sub { $self->_successors($spec->match_expr,$state,$depth+1,$root,$group) });
   }
   if (($name eq 'HAS' || $name eq 'IS') && !exists $spec->{value_expr}) {
      local $match->{exact}=$name eq 'IS';
      return [] if $state->{pos}>=$self->_size;
      my $states=$self->_successors($spec->match_spec,$state,$depth+1,$root,$group);
      return $self->_unique([map $self->_state($state->{pos}+1,$_->{caps},$_->{prefs},$_->{sub},$_->{seen}), @$states]);
   }
   if ($name eq 'SEQ' || $name eq 'SEQMIN' || $name eq 'SEQMAX') {
      $root || $name eq 'SEQ' or $exec->_fail('INVALID_GRAFT','Named sequence must be an array-elements root');
      my $reserved=$match->{reserved} || {};
      if ($root && $group && ($group->{deferred} || refaddr($group->{node})!=refaddr($spec))) {
         $exec->_tick(scalar keys %$reserved);
         $self->_scratch(64*keys %$reserved);
         $reserved={%$reserved};
         delete $reserved->{$group->{name}} if exists $group->{name};
         local $self->{reserved}=$reserved;
         my $actual=$self->_root($spec,$depth+1);
         $actual->{slot}=$group->{slot} if exists $group->{slot};
         $group=$actual;
      }
      local $match->{reserved}=$reserved;
      my $floor=$self->{workspace}[1];
      my $states=$self->_walk($spec->match_exprs,[$state],$depth);
      if ($root && $group) {
         my $live=$self->_vector_bytes($states);
         my @out;
         my $out_bytes=0;
         $exec->_tick(scalar @$states);
         for my $candidate (@$states) {
            $self->_prune($floor,$live+80+$out_bytes);
            my $length=$candidate->{pos}-$state->{pos};
            my $caps=$candidate->{caps};
            if (exists $group->{name}) {
               my $range=$exec->_alloc_hash(4);
               my @path;
               for (my $link=$self->{parent}{path}; $link; $link=$link->[0]) {
                  $self->_scratch(16); push @path,$link->[1]; $exec->_tick(1);
               }
               my $path=$exec->_alloc_array(scalar @path);
               $exec->_tick(scalar @path);
               @$path=reverse @path;
               %$range=(path=>$path,ofs=>$state->{pos},len=>$length,lim=>$candidate->{pos});
               $caps=$self->_add_capture($caps,$group->{name},$range);
            }
            $self->_scratch(144+16*@{$candidate->{prefs}});
            my @prefs=@{$candidate->{prefs}};
            $prefs[$group->{slot}]=exists $group->{preference}
               ? [$group->{preference}*$length,$state->{pos}] : [0,0] if exists $group->{slot};
            push @out,$self->_state($candidate->{pos},$caps,\@prefs,$candidate->{sub},1);
            $out_bytes+=16+$out[-1]{bytes};
         }
         return \@out;
      }
      return $states;
   }
   if ($name eq 'REP') { return $self->_repeat($spec,$state,$depth) }
   if ($name eq 'START' || $name eq 'END') {
      return ($name eq 'START'? $state->{pos}==0 : $state->{pos}==$self->_size)? [$state] : [];
   }
   if ($name eq 'ANY' || $name eq 'NONE') {
      local $match->{suppress_captures}=1;
      my @out;
      my $floor=$self->{workspace}[1];
      my $out_bytes=0;
      $exec->_tick(scalar @{$spec->match_exprs});
      for my $arg (@{$spec->match_exprs}) {
         $self->_prune($floor,80+$out_bytes);
         my $states=$self->_successors($arg,$state,$depth+1,0,undef);
         return [] if $name eq 'NONE' && @$states;
         $self->_scratch(16*@$states);
         $out_bytes+=$self->_vector_bytes($states)-80;
         push @out,@$states;
      }
      return $name eq 'NONE'? [$state] : $self->_unique(\@out);
   }
   if ($name eq 'ALL') { return $self->_all($spec,$state,$depth) }
   if (($name eq 'HAS' || $name eq 'IS') && exists $spec->{value_expr}) {
      local $match->{regex_element}=1;
      return $match->_test($spec,$cursor,$depth+1,0)? [$self->_state($state->{pos},$match->{captures},$state->{prefs},$state->{sub},$state->{seen})] : [];
   }
   return $self->_text($exec->_eval($spec,$depth+1),$state,$depth)
      if $self->{string} && is_expr($spec) && !$spec->is_match;
   return $self->_element($spec,$state,$cursor,$depth,0);
}
sub _element {
   my ($self,$spec,$state,$cursor,$depth,$literal)=@_;
   return [] if $state->{pos}>=$self->_size;
   local $self->{match}{sequence}=undef;
   local $self->{match}{regex_element}=1;
   return [] unless $self->{match}->_test($spec,$cursor,$depth+1,$literal);
   my $caps=$self->{match}{captures};
   my $sub=$state->{sub};
   if (refaddr($caps)!=refaddr($state->{caps})) {
      $self->_scratch(96+16*@$sub);
      $sub=[@$sub,$state->{pos}];
   }
   return [$self->_state($state->{pos}+1,$caps,$state->{prefs},$sub,$state->{seen})];
}
sub _add_capture {
   my ($self,$caps,$name,$range)=@_;
   my $exec=$self->{exec};
   exists $caps->{$name} and $exec->_fail('INVALID_OPERAND','Duplicate capture name');
   my $copy=$exec->_copy_hash($caps,1+keys %$caps);
   $exec->_set_member($copy,$name,$range);
   return $copy;
}
sub _repeat {
   my ($self,$expr,$state,$depth)=@_;
   my $exec=$self->{exec};
   my $min=exists $expr->{min}? $exec->_eval($expr->min,$depth+1) : 0;
   my $max=exists $expr->{max}? $exec->_eval($expr->max,$depth+1) : -1;
   is_integer($min) && $min>=0 && is_integer($max) && $max>=-1
      or $exec->_fail('INVALID_OPERAND','Invalid REP bounds');
   ($min,$max)=map $exec->_number($_,$self->{workspace}),($min,$max) if ref($min) || ref($max);
   $max=$min if $max==0;
   $max==-1 || $max>=$min or $exec->_fail('INVALID_OPERAND','REP maximum is below minimum');
   local $self->{match}{suppress_captures}=1;
   my $floor=$self->{workspace}[1];
   $self->_scratch(176);
   my $front=[$state];
   my $front_bytes=$self->_vector_bytes($front);
   my @accepted=$min==0? ($state) : ();
   my $accepted_bytes=@accepted? 16+$state->{bytes} : 0;
   my $count=0;
   while (@$front && ($max==-1 || $count<$max)) {
      my $live=$front_bytes;
      $self->_prune($floor,$live+160+$accepted_bytes);
      my @next;
      my $next_bytes=0;
      my $visited=0;
      $exec->_tick(scalar @$front);
      for my $candidate (@$front) {
         $self->_prune($floor,$live+160+$accepted_bytes+$next_bytes) if $visited++;
         if (exists $expr->{match_expr}) {
            my $found=$self->_successors($expr->match_expr,$candidate,$depth+1,0,undef);
            $self->_scratch(16*@$found);
            $next_bytes+=$self->_vector_bytes($found)-80;
            push @next,@$found;
         }
         elsif ($self->_present($candidate->{pos})) {
            push @next,$self->_state($candidate->{pos}+1,$candidate->{caps},$candidate->{prefs},$candidate->{sub},$candidate->{seen});
            $next_bytes+=16+$next[-1]{bytes};
         }
      }
      my $next=$self->_unique(\@next);
      my $new_bytes=@$next<2?80+$next_bytes:$self->_vector_bytes($next);
      ++$count;
      if ($count>=$min) {
         $self->_scratch(16*@$next);
         $accepted_bytes+=$new_bytes-80;
         push @accepted,@$next;
      }
      $exec->_tick(@$next+@$front);
      my $stable;
      if (@$front==1 && @$next==1) { $stable=$front->[0]{pos}==$next->[0]{pos} }
      elsif (@$front==@$next) {
         $self->_scratch(128+64*@$front);
         my %positions=map { (0+$_->{pos})=>1 } @$front;
         $stable=!grep !$positions{0+$_->{pos}}, @$next;
      }
      if ($stable) {
         if ($count<$min) { $self->_scratch(16*@$next); push @accepted,@$next }
         last;
      }
      $front=$next;
      $front_bytes=$new_bytes;
   }
   return $self->_unique(\@accepted);
}
sub _all {
   my ($self,$expr,$state,$depth)=@_;
   my $exec=$self->{exec};
   my $floor=$self->{workspace}[1];
   my $argument_bytes=0;
   my (@arguments,%ends);
   $exec->_tick(scalar @{$expr->match_exprs});
   for my $arg (@{$expr->match_exprs}) {
      $self->_prune($floor,208+$argument_bytes+64*keys %ends);
      my $states=$self->_successors($arg,$state,$depth+1,0,undef);
      return [] unless @$states;
      $self->_scratch(16+64*@$states);
      $argument_bytes+=16+$self->_vector_bytes($states);
      push @arguments,$states;
      $exec->_tick(scalar @$states);
      $ends{0+$_->{pos}}=1 for @$states;
   }
   my $live=288+$argument_bytes+80*keys %ends;
   $self->_prune($floor,$live);
   my @out;
   my $out_bytes=0;
   ENDPOINT: for my $key (keys %ends) {
      $self->_prune($floor,$live+$out_bytes);
      my $end=0+$key;
      my $caps=$state->{caps};
      $self->_scratch(80+16*@{$state->{sub}});
      my @sub=@{$state->{sub}};
      $exec->_tick(scalar @arguments);
      for my $states (@arguments) {
         my $nearest;
         $exec->_tick(scalar @$states);
         for my $candidate (@$states) {
            next if $candidate->{pos}>$end;
            $nearest=$candidate if !$nearest || $candidate->{pos}>$nearest->{pos};
         }
         next ENDPOINT unless $nearest;
         $exec->_tick(scalar keys %{$nearest->{caps}});
         for my $name (keys %{$nearest->{caps}}) {
            next if exists $state->{caps}{$name};
            $caps=$self->_add_capture($caps,$name,$nearest->{caps}{$name});
         }
         my $extra=@{$nearest->{sub}}-@{$state->{sub}};
         $self->_scratch(32*$extra) if $extra>0;
         push @sub,@{$nearest->{sub}}[@{$state->{sub}}..$#{$nearest->{sub}}];
      }
      push @out,$self->_state($end,$caps,$state->{prefs},\@sub,$state->{seen});
      $out_bytes+=16+$out[-1]{bytes};
   }
   return $self->_unique(\@out);
}

1;
