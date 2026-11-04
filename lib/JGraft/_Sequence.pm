package JGraft::_Sequence;
# VERSION
# ABSTRACT: Array and string successors and observable capture selection
use strict;
use warnings;
no warnings 'recursion';
use Scalar::Util 'refaddr';
use JGraft::Util qw(:types type_mask is_expr is_integer);

sub _new {
   my ($class,$match,$value,$cursor,$offset,$exact,$suffix)=@_;
   $match->{exec}->_step(scalar keys %{$match->{reserved} || {}});
   $match->{exec}->_charge('mem',160+64*keys %{$match->{reserved} || {}});
   return bless {match=>$match,exec=>$match->{exec},value=>$value,parent=>$cursor,
      offset=>$offset,exact=>$exact,suffix=>$suffix,string=>ref($value) eq 'JGraft::_String',groups=>[],reserved=>{%{$match->{reserved} || {}}}},$class;
}
sub _size { $_[0]{string}? $_[0]{value}{size} : scalar @{$_[0]{value}} }
sub _present { $_[0]{string}? $_[1]<$_[0]->_size : $_[0]{exec}->_present($_[0]{value},$_[1]) }
sub _cursor {
   my ($self,$position)=@_;
   my $value=$self->{value};
   my $exists=$self->_present($position);
   my $cursor=$self->{match}->_cursor($exists? ($self->{string}? $value->_at($position) : $value->[$position]) : undef,$exists,$position,
      [$self->{parent}{path},$position],$self->{parent}{anchored});
   $cursor->{$self->{string}? 'string' : 'array'}=$value;
   return $cursor;
}
sub _state {
   my ($self,$position,$caps,$prefs,$sub,$seen)=@_;
   $self->{exec}->_step(1);
   $self->{exec}->_charge('mem',80+16*(@$prefs+@$sub));
   return {pos=>$position,caps=>$caps,prefs=>$prefs,sub=>$sub,seen=>$seen || 0};
}
sub _with {
   my ($self,$expr,$depth,$callback)=@_;
   my $exec=$self->{exec};
   my $temp=$exec->_new_hash(scalar keys %{$exec->{temp}[0]});
   $exec->_step(scalar keys %{$exec->{temp}[0]});
   %$temp=%{$exec->{temp}[0]};
   local $exec->{temp}=[$temp,1];
   $exec->_step(scalar @{$expr->bindings});
   for my $pair (@{$expr->bindings}) {
      my $key=$pair->[0]; $key="$key";
      $exec->_put($temp,$key,$exec->_eval($pair->[1],$depth+1));
   }
   return $callback->();
}

# Root declarations are inspected before exploring endpoints. Names are evaluated
# with NODE missing, but the declaration's lexical TEMP overlay remains visible.
sub _root {
   my ($self,$spec,$depth)=@_;
   my $exec=$self->{exec};
   $exec->_depth($depth); $exec->_step(1);
   return unless is_expr($spec);
   my $name=$spec->_name;
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
         $exec->_charge('mem',64+4*length($key));
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
   $exec->_step(scalar @$specs);
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
   $self->{exec}->_step(1);
   return 0 unless is_expr($spec);
   my $id=refaddr($spec);
   return 0 if $active->{$id};
   local $active->{$id}=1;
   my $name=$spec->_name;
   if ($name eq 'EXPR') {
      return 1 if is_expr($spec->name);
      my $key=$spec->name; $key="$key";
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
   $self->{exec}->_depth($depth); $self->{exec}->_step(1);
   return 0 unless is_expr($spec);
   my $id=refaddr($spec);
   return 0 if $active->{$id};
   local $active->{$id}=1;
   my $name=$spec->_name;
   return 1 if $name eq 'SEQ' || $name eq 'SEQMIN' || $name eq 'SEQMAX';
   return $self->_potential($spec->match_expr,$active,$depth+1) if $name eq 'WITH';
   return $self->_potential($spec->match_spec,$active,$depth+1)
      if ($name eq 'HAS' || $name eq 'IS') && !exists $spec->{value_expr};
   if ($name eq 'EXPR') {
      return 1 if is_expr($spec->name);
      my $key=$spec->name; $key="$key";
      return 0 unless exists $self->{exec}{expr}[0]{$key};
      return $self->_potential($self->{exec}{expr}[0]{$key},$active,$depth+1);
   }
   return 0;
}

sub _kind_at {
   my ($self,$spec,$depth)=@_;
   $self->{exec}->_depth($depth); $self->{exec}->_step(1);
   return 0 unless is_expr($spec);
   my $name=$spec->_name;
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
   local $self->{match}{sequence}=undef;
   my $size=$self->_size;
   my $end=$self->{offset}+@$specs;
   return 0 if $end>$size+1;
   if ($end<$size && ($self->{exact} || $self->{suffix})) {
      $exec->_step($size-$end);
      for my $i ($end..$size-1) {
         my $present=$self->_present($i);
         return 0 if $self->{exact}? $present : !$present;
      }
   }
   $exec->_step(scalar @$specs);
   for my $i (0..$#$specs) {
      my $cursor=$self->_cursor($self->{offset}+$i);
      {
         local $exec->{current}=[[$cursor->{value},$cursor->{exists}],[]];
         local $exec->{match_cursor}=$cursor;
         return 0 if $self->{match}->_probe(sub { $self->_kind_at($specs->[$i],$depth+1) });
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
   $self->{exec}->_step(2*$n+@{$a->{sub}}+1);
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
   $self->{exec}->_step(scalar @$states);
   my %best;
   for my $state (@$states) {
      my $key=0+$state->{pos};
      $best{$key}=$state if $self->_better($state,$best{$key});
   }
   return [values %best];
}
sub _walk {
   my ($self,$specs,$states,$depth)=@_;
   $self->{exec}->_step(scalar @$specs);
   for my $spec (@$specs) {
      my @next;
      $self->{exec}->_step(scalar @$states);
      for my $state (@$states) { push @next,@{$self->_successors($spec,$state,$depth+1,0,undef)} }
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
   $self->{exec}->_step($self->{slots});
   $self->{exec}->_charge('mem',64*$self->{slots});
   my $states=[$self->_state($self->{offset},$match->{captures},[map [0,0],1..$self->{slots}],[])];
   $self->{exec}->_step(scalar @$specs);
   for my $i (0..$#$specs) {
      my @next;
      $self->{exec}->_step(scalar @$states);
      for my $state (@$states) {
         push @next,@{$self->_successors($specs->[$i],$state,$depth+1,1,$self->{groups}[$i])};
      }
      $states=$self->_unique(\@next);
      return $self->{deferred}? $self->_ordinary($specs,$depth) : 0 unless @$states;
   }
   my $best;
   $self->{exec}->_step(scalar @$states);
   for my $state (@$states) {
      next unless $state->{seen};
      next if $self->{exact} && $state->{pos}!=$self->_size;
      if ($self->{suffix}) {
         my $present=1;
         $self->{exec}->_step($self->_size-$state->{pos});
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
   $self->{exec}->_charge('mem',64*$self->{slots});
   my $last=defined($position)? $position : $self->_size;
   my $start=defined($position)? $position : 0;
   for (my $i=$start;$i<=$last;++$i) {
      my $state=$self->_state($i,$match->{captures},[map [0,0],1..$self->{slots}],[]);
      my $states=$self->_successors($spec,$state,$depth+1,1,$self->{groups}[0]);
      my $best;
      $self->{exec}->_step(scalar @$states);
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
      $size=1 if $self->_present($state->{pos}) && $self->{value}->_at($state->{pos})==$spec;
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
   $self->{exec}->_step(scalar @$states);
   for my $candidate (@$states) {
      next if defined($end) && $candidate->{pos}!=$end;
      $best=$candidate->{pos} if !defined($best) || $candidate->{pos}>$best;
   }
   return defined($best)? $best-$position : undef;
}

sub _successors {
   my ($self,$spec,$state,$depth,$root,$group)=@_;
   my $exec=$self->{exec};
   $exec->_depth($depth); $exec->_step(1);
   my $cursor=$self->_cursor($state->{pos});
   local $exec->{expression}=is_expr($spec)? $spec : $exec->{expression};
   local $exec->{current}=[[$cursor->{value},$cursor->{exists}],[]];
   local $exec->{match_cursor}=$cursor;
   local $self->{match}{captures}=$state->{caps};
   return $self->{match}->_probe(sub {
      $self->_dispatch($spec,$state,$cursor,$depth,$root,$group)
   }) || [];
}
sub _dispatch {
   my ($self,$spec,$state,$cursor,$depth,$root,$group)=@_;
   my $exec=$self->{exec};
   my $match=$self->{match};
   my $name=is_expr($spec)? $spec->_name : '';
   return $self->_text($spec,$state,$depth) if $self->{string} && !is_expr($spec);
   if ($name eq 'EXPR') {
      my $body=$exec->_macro($spec,$depth+1);
      return $self->_successors($body,$state,$depth+1,$root,$group)
         if is_expr($body) && ($body->is_match || $body->_name eq 'EXPR');
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
         $exec->_step(scalar keys %$reserved);
         $exec->_charge('mem',64*keys %$reserved);
         $reserved={%$reserved};
         delete $reserved->{$group->{name}} if exists $group->{name};
         local $self->{reserved}=$reserved;
         my $actual=$self->_root($spec,$depth+1);
         $actual->{slot}=$group->{slot} if exists $group->{slot};
         $group=$actual;
      }
      local $match->{reserved}=$reserved;
      my $states=$self->_walk($spec->match_exprs,[$state],$depth);
      if ($root && $group) {
         my @out;
         $exec->_step(scalar @$states);
         for my $candidate (@$states) {
            my $length=$candidate->{pos}-$state->{pos};
            my $caps=$candidate->{caps};
            if (exists $group->{name}) {
               my $range=$exec->_new_hash(4);
               my @path;
               for (my $link=$self->{parent}{path}; $link; $link=$link->[0]) { push @path,$link->[1]; $exec->_step(1) }
               my $path=$exec->_new_array(scalar @path);
               $exec->_step(scalar @path);
               @$path=reverse @path;
               %$range=(path=>$path,ofs=>$state->{pos},len=>$length,lim=>$candidate->{pos});
               $caps=$self->_add_capture($caps,$group->{name},$range);
            }
            my @prefs=@{$candidate->{prefs}};
            $prefs[$group->{slot}]=exists $group->{preference}
               ? [$group->{preference}*$length,$state->{pos}] : [0,0] if exists $group->{slot};
            push @out,$self->_state($candidate->{pos},$caps,\@prefs,$candidate->{sub},1);
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
      $exec->_step(scalar @{$spec->match_exprs});
      for my $arg (@{$spec->match_exprs}) {
         my $states=$self->_successors($arg,$state,$depth+1,0,undef);
         return [] if $name eq 'NONE' && @$states;
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
   $sub=[@$sub,$state->{pos}] if refaddr($caps)!=refaddr($state->{caps});
   return [$self->_state($state->{pos}+1,$caps,$state->{prefs},$sub,$state->{seen})];
}
sub _add_capture {
   my ($self,$caps,$name,$range)=@_;
   my $exec=$self->{exec};
   exists $caps->{$name} and $exec->_fail('INVALID_OPERAND','Duplicate capture name');
   my $copy=$exec->_new_hash(1+keys %$caps);
   $exec->_step(scalar keys %$caps);
   %$copy=%$caps;
   $exec->_put($copy,$name,$range);
   return $copy;
}
sub _repeat {
   my ($self,$expr,$state,$depth)=@_;
   my $exec=$self->{exec};
   my $min=exists $expr->{min}? $exec->_eval($expr->min,$depth+1) : 0;
   my $max=exists $expr->{max}? $exec->_eval($expr->max,$depth+1) : -1;
   is_integer($min) && $min>=0 && is_integer($max) && $max>=-1
      or $exec->_fail('INVALID_OPERAND','Invalid REP bounds');
   $max=$min if $max==0;
   $max==-1 || $max>=$min or $exec->_fail('INVALID_OPERAND','REP maximum is below minimum');
   local $self->{match}{suppress_captures}=1;
   my $front=[$state];
   my @accepted=$min==0? ($state) : ();
   my $count=0;
   while (@$front && ($max==-1 || $count<$max)) {
      my @next;
      $exec->_step(scalar @$front);
      for my $candidate (@$front) {
         if (exists $expr->{match_expr}) {
            push @next,@{$self->_successors($expr->match_expr,$candidate,$depth+1,0,undef)};
         }
         elsif ($self->_present($candidate->{pos})) {
            push @next,$self->_state($candidate->{pos}+1,$candidate->{caps},$candidate->{prefs},$candidate->{sub},$candidate->{seen});
         }
      }
      my $next=$self->_unique(\@next);
      ++$count;
      push @accepted,@$next if $count>=$min;
      my %positions=map { (0+$_->{pos})=>1 } @$front;
      $exec->_step(@$next+@$front);
      my $stable=@$front==@$next && !grep !$positions{0+$_->{pos}}, @$next;
      if ($stable) {
         push @accepted,@$next if $count<$min;
         last;
      }
      $front=$next;
   }
   return $self->_unique(\@accepted);
}
sub _all {
   my ($self,$expr,$state,$depth)=@_;
   my $exec=$self->{exec};
   my (@arguments,%ends);
   $exec->_step(scalar @{$expr->match_exprs});
   for my $arg (@{$expr->match_exprs}) {
      my $states=$self->_successors($arg,$state,$depth+1,0,undef);
      return [] unless @$states;
      push @arguments,$states;
      $exec->_step(scalar @$states);
      $ends{0+$_->{pos}}=1 for @$states;
   }
   my @out;
   ENDPOINT: for my $key (keys %ends) {
      my $end=0+$key;
      my $caps=$state->{caps};
      my @sub=@{$state->{sub}};
      $exec->_step(scalar @arguments);
      for my $states (@arguments) {
         my $nearest;
         $exec->_step(scalar @$states);
         for my $candidate (@$states) {
            next if $candidate->{pos}>$end;
            $nearest=$candidate if !$nearest || $candidate->{pos}>$nearest->{pos};
         }
         next ENDPOINT unless $nearest;
         $exec->_step(scalar keys %{$nearest->{caps}});
         for my $name (keys %{$nearest->{caps}}) {
            next if exists $state->{caps}{$name};
            $caps=$self->_add_capture($caps,$name,$nearest->{caps}{$name});
         }
         push @sub,@{$nearest->{sub}}[@{$state->{sub}}..$#{$nearest->{sub}}];
      }
      push @out,$self->_state($end,$caps,$state->{prefs},\@sub,$state->{seen});
   }
   return $self->_unique(\@out);
}

1;
