package JGraft::_Split;
# VERSION
# ABSTRACT: Split specifications, tokenization, and metadata-aware reassembly
use strict;
use warnings;
use Scalar::Util 'refaddr';
use JGraft::Util qw(:types type_mask is_expr);
use JGraft::_String;
use JGraft::_Match;
use JGraft::_Sequence;

sub _resolve {
   my ($class,$exec,$value,$depth)=@_;
   while (is_expr($value) && $value->_name eq 'EXPR') {
      $exec->_depth(++$depth); $exec->_step(1);
      $value=$exec->_macro($value,$depth);
   }
   return $value if is_expr($value) && $value->is_match;
   $value=$exec->_eval($value,$depth+1);
   type_mask($value)==TYPE_STRING or $exec->_fail('INVALID_OPERAND','Split pattern must resolve to a string or match expression');
   return $value;
}
sub _config {
   my ($class,$exec,$spec,$depth,$mode)=@_;
   my $raw=ref($spec) eq 'HASH'? $spec : {sep=>$spec};
   $exec->_step(scalar keys %$raw);
   $exec->_charge('mem',256);
   my $out={};
   for my $key (qw(sep element trim ltrim rtrim)) {
      next if $mode eq 'join' && $key ne 'sep';
      next unless exists $raw->{$key};
      $out->{$key}=$class->_resolve($exec,$raw->{$key},$depth+1);
   }
   @{$out}{qw(ltrim rtrim)}=($out->{trim},$out->{trim}) if exists $out->{trim};
   $out->{keep}=$raw->{keep};
   $out->{discard}=$raw->{discard};
   if ($mode ne 'split') {
      if ($out->{keep}) { $out->{default}='' }
      elsif (!is_expr($out->{sep})) { $out->{default}=$out->{sep} }
      else {
         exists $raw->{default} or $exec->_fail('INVALID_OPERAND','Regex joining requires a default separator');
         $out->{default}=$exec->_eval($raw->{default},$depth+1);
         type_mask($out->{default})==TYPE_STRING or $exec->_fail('INVALID_OPERAND','Default separator must be a string');
      }
   }
   return $out;
}
sub _span {
   my ($class,$exec,$pattern,$view,$position,$depth,$end)=@_;
   if (!is_expr($pattern)) {
      my $length=$view->_literal($exec,$pattern,$position);
      return if defined($end) && defined($length) && $position+$length!=$end;
      return $length;
   }
   my $match=JGraft::_Match->_new($exec,0);
   my $cursor=$match->_cursor(undef,0,undef,undef);
   my $sequence=JGraft::_Sequence->_new($match,$view,$cursor,0,0);
   return $sequence->_span($pattern,$depth+1,$position,$end);
}
sub _view {
   my ($class,$exec,$view,$offset,$size)=@_;
   $exec->_step($size*.001+1);
   $exec->_charge('mem',128+$view->{width}*$size);
   return bless {width=>$view->{width},size=>$size,
      buffer=>substr($view->{buffer},$offset*$view->{width},$size*$view->{width})},'JGraft::_String';
}
sub _text {
   my ($class,$exec,$text,$offset,$size)=@_;
   $exec->_step(($offset+$size)*.001+1);
   $exec->_charge('mem',4*$size);
   return substr($text,$offset,$size);
}
sub _field {
   my ($class,$exec,$config,$text,$sep,$array,$rows,$depth)=@_;
   my ($left,$right)=('','');
   if (exists($config->{ltrim}) || exists($config->{rtrim})) {
      my $view=JGraft::_String->_new($exec,$text,'split field');
      my $start=0;
      if (exists $config->{ltrim}) {
         $start=$class->_span($exec,$config->{ltrim},$view,0,$depth+1) || 0;
         $left=$class->_text($exec,$text,0,$start);
      }
      my $end=length($text);
      if (exists $config->{rtrim}) {
         my $remainder=$class->_view($exec,$view,$start,$end-$start);
         for (my $i=0;$i<=$remainder->{size};++$i) {
            $exec->_step(1);
            my $length=$class->_span($exec,$config->{rtrim},$remainder,$i,$depth+1,$remainder->{size});
            if (defined $length) { $end=$start+$i; last }
         }
         $right=$class->_text($exec,$text,$end,length($text)-$end);
      }
      $text=$class->_text($exec,$text,$start,$end-$start);
   }
   $exec->_step(1); $exec->_charge('mem',16+($rows?80:0));
   push @$array,$text;
   push @$rows,[$config->{keep} || !is_expr($config->{sep})? '' : $sep,
      $config->{discard}? '' : $left,$config->{discard}? '' : $right] if $rows;
}
sub _split {
   my ($class,$exec,$config,$text,$depth)=@_;
   type_mask($text)==TYPE_STRING or $exec->_fail('INVALID_TARGET','SPLIT expects a string');
   my $view=JGraft::_String->_new($exec,$text,'split subject');
   my $array=$exec->_new_array(0);
   my ($start,$field_start,$position,$last_sep,$tail)=(0,0,0,'',1);
   my $keep=$config->{keep} || '';
   my $separators=!$keep && is_expr($config->{sep});
   my $trims=!$config->{discard} && (exists($config->{ltrim}) || exists($config->{rtrim}));
   my $rows=$separators || $trims? [] : undef;
   while ($position<=$view->{size}) {
      $exec->_step(1);
      my $length=$class->_span($exec,$config->{sep},$view,$position,$depth+1);
      if (!defined($length) || (!$length && $position==$start)) {
         $tail=0 if !$view->{size} && defined($length) && !$length;
         ++$position; next;
      }
      if (exists $config->{element}) {
         my $element=$class->_view($exec,$view,$start,$position-$start);
         unless (defined $class->_span($exec,$config->{element},$element,0,$depth+1,$element->{size})) {
            ++$position; next;
         }
      }
      $last_sep=$class->_text($exec,$text,$position,$length);
      my $end=$position+($keep eq '<'? $length : 0);
      $class->_field($exec,$config,$class->_text($exec,$text,$field_start,$end-$field_start),$last_sep,$array,$rows,$depth+1);
      $class->_field($exec,$config,$last_sep,'',$array,$rows,$depth+1) if $keep eq '@';
      $start=$position+$length;
      $field_start=$keep eq '>'? $position : $start;
      if (!$length && $position==$view->{size}) { $tail=0; last }
      $position=$start;
   }
   $class->_field($exec,$config,$class->_text($exec,$text,$field_start,length($text)-$field_start),$last_sep,$array,$rows,$depth+1) if $tail;
   if (@$array && ($separators || $trims)) {
      $exec->_charge('mem',160);
      $exec->{split_meta}{refaddr($array)}={array=>$array,origin=>++$exec->{split_origin},
         rows=>$rows,separators=>$separators,trims=>$trims};
   }
   return $array;
}
sub _join {
   my ($class,$exec,$config,$array,$depth)=@_;
   ref($array) eq 'ARRAY' or $exec->_fail('INVALID_TARGET','JOIN expects an array');
   my $meta=$exec->{split_meta}{refaddr($array)};
   my (@parts,$size);
   $size=0;
   $exec->_step(scalar @$array);
   $exec->_charge('mem',64*@$array);
   for my $i (0..$#$array) {
      $exec->_present($array,$i) && type_mask($array->[$i])==TYPE_STRING
         or $exec->_fail('INVALID_TARGET','JOIN elements must be strings');
      my $row=$meta && $meta->{rows}[$i];
      my $left=$row && $meta->{trims} && !$config->{discard}? $row->[1] : '';
      my $right=$row && $meta->{trims} && !$config->{discard}? $row->[2] : '';
      my $sep=$i==$#$array? '' : !$config->{keep} && is_expr($config->{sep}) && $row && $meta->{separators}? $row->[0] : $config->{default};
      push @parts,$left,$array->[$i],$right,$sep;
      $size+=length($left)+length($array->[$i])+length($right)+length($sep);
   }
   $exec->_step($size*.001);
   $exec->_charge('mem',4*$size);
   return join('',@parts);
}

# Metadata rows are immutable. Clones/slices share rows but own the parallel list.
sub _copy_meta {
   my ($class,$exec,$source,$target,$offset,$size)=@_;
   my $meta=$exec->{split_meta}{refaddr($source)} or return;
   return unless $size;
   $exec->_step($size); $exec->_charge('mem',160+16*$size);
   $exec->{split_meta}{refaddr($target)}={%$meta,array=>$target,rows=>[@{$meta->{rows}}[$offset..$offset+$size-1]]};
}
sub _source {
   my ($class,$exec,$loc)=@_;
   return unless @{$loc->[1]} && keys %{$exec->{split_meta}};
   my @parts=@{$loc->[1]};
   my $index=pop @parts;
   my ($parent)=$exec->_read([$loc->[0],\@parts]);
   return unless ref($parent) eq 'ARRAY';
   my $meta=$exec->{split_meta}{refaddr($parent)} or return;
   $exec->_charge('mem',128);
   return {origin=>$meta->{origin},separators=>$meta->{separators},trims=>$meta->{trims},row=>$meta->{rows}[$index]};
}
sub _insert_meta {
   my ($class,$exec,$array,$source)=@_;
   my $meta=$exec->{split_meta}{refaddr($array)};
   if (!$meta && $source) {
      $exec->_step(scalar @$array); $exec->_charge('mem',160+96*@$array);
      $meta={array=>$array,origin=>$source->{origin},
         separators=>$source->{separators},trims=>$source->{trims},rows=>[(undef)x scalar @$array]};
   }
   return unless $meta;
   my $pending=$exec->{pending}{refaddr($array)};
   if ($pending && !$pending->{metadata}) {
      $exec->_step(2*@$array); $exec->_charge('mem',96*@$array);
      $pending->{metadata}=1;
   }
   $exec->{split_meta}{refaddr($array)}=$meta;
   return $source && $source->{origin}==$meta->{origin}? $source->{row} : undef;
}
sub _fill_meta {
   my ($class,$exec,$array,$reserved)=@_;
   my $meta=$exec->{split_meta}{refaddr($array)} or return;
   unless (@$array) { delete $exec->{split_meta}{refaddr($array)}; return }
   $exec->_step(2*@$array) unless $reserved;
   my $anchor;
   for my $row (@{$meta->{rows}}) { if ($row) { $anchor=$row; last } }
   unless ($anchor) { delete $exec->{split_meta}{refaddr($array)}; return }
   my $next_sep=$anchor->[0];
   my $previous;
   for my $i (0..$#$array) {
      my $row=$meta->{rows}[$i];
      unless ($row) {
         $row=[$previous? $previous->[0] : $next_sep,$previous? $previous->[1] : '',''];
         $meta->{rows}[$i]=$row;
      }
      $previous=$row;
   }
}

1;
