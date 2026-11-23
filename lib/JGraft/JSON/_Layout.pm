package JGraft::JSON::_Layout;
# VERSION
# ABSTRACT: Shared whitespace and comment records for JGraft::JSON containers
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util 'refaddr';
use JGraft::Util ();
our @EXPORT_OK=qw(V_PRE M_PRE POST K_PRE C_PRE C_POST final_ws has_comments strip_value
   container_layout document_layout arrange same_origin);

# Layout data is private to JGraft::JSON and its container ties.
#
# Decoding with retained whitespace or comments records only token positions.
# The document is a shared hash:
#    { text=>original text as UTF-8 bytes, wide=>text is not all ASCII,
#      t=>[start, end, match, ...], id=>number,
#      cw/cc=>whitespace/comments retained, cm=>comments accepted, j5, ascii,
#      root=>[first, last token of the root value], cache=>{...} }
# Every position is a byte offset; text cut from the document is decoded to
# characters before it reaches the encoder (records below hold characters).
# t holds three integers per token: its byte bounds, and for an opening
# bracket the index of its closing bracket. Comments are tokens; whitespace is
# the text between tokens. Containers are tied to JGraft::JSON::Object or
# JGraft::JSON::Array, holding doc, open (their opening token index), and mod
# (set by any modification). Objects also map each slot to its original member
# index (orig). Decoded numbers and strings record their document id and
# byte offset (src and at), not a reference, so they can be recognized
# when encoding without keeping the document alive.
#
# The encoder reconstructs the following records from the token positions on
# first use, caching them in the document.
#
# A gap is the text between two tokens:
#    undef      not captured or newly created: the encoder chooses it
#    'string'   one whitespace item, without comments
#    [items]    whitespace and comments: (ws, comment, ws, ..., ws) for a leading
#               gap, or (ws, comment, ..., comment) for a trailing gap
# Whitespace items are literal text, undef when whitespace was not retained, or
# "\0" . newlines . relative_indent when the final line's indent begins with the
# container's own line indent. Comments begin with '/' (verbatim) or
# "\0indent\0/" for a multi-line comment whose first line had that indent.
#
# Member records are arrays of gaps. The first three fields belong to the value
# token and are shared by array elements and object members:
#    V_PRE   before the value (array) or between colon comments and value (object)
#    M_PRE   between the value and its comma (or the closing token if last)
#    POST    trailing comments after that comma or value
# Object members add key-owned fields:
#    K_PRE   before the key
#    C_PRE   between the key and the colon
#    C_POST  trailing comments after the colon
# An undefined record means every gap was empty; [] means every gap uses defaults.
#
# A container's outer record:
#    { ws=>whitespace retained, ml=>contained newlines, base=>line indent,
#      open=>trailing gap after the opening token, close=>gap before closing,
#      tc=>trailing comma }
use constant { V_PRE=>0, M_PRE=>1, POST=>2, K_PRE=>3, C_PRE=>4, C_POST=>5 };

sub final_ws {
   my $gap=shift;
   return $gap unless ref $gap;
   return @$gap%2? $gap->[-1] : undef;
}
sub lead_ws {
   my ($rec,$lead)=@_;
   return defined($rec)? final_ws($rec->[$lead]) : '';
}
# Neighbor-derived whitespace for new members: comments are not copied.
sub ws_only {
   my $rec=shift;
   return undef unless defined $rec;
   my @out=map +(ref($_)? final_ws($_) : $_),@$rec;
   $out[POST]=undef;
   $out[C_POST]=undef if @out>C_POST;
   return \@out;
}
# Replacing a value discards comments attached to it, keeping whitespace.
sub strip_value {
   my $rec=shift;
   return $rec unless defined($rec) && (ref($rec->[V_PRE]) || ref($rec->[M_PRE]) || defined($rec->[POST]));
   my @out=@$rec;
   $out[$_]=final_ws($out[$_]) for V_PRE,M_PRE;
   $out[POST]=undef;
   return \@out;
}
sub set_lead {
   my ($rec,$lead,$ws,$size)=@_;
   my @out=defined($rec)? @$rec : ('') x $size;
   my $gap=$out[$lead];
   if (ref $gap) {
      my @items=@$gap;
      if (@items%2) { $items[-1]=$ws } else { push @items,$ws }
      $out[$lead]=\@items;
   }
   else { $out[$lead]=$ws }
   return \@out;
}
# Records for the current members, given each one's original member index (or
# undef when new) and whether its value was replaced. The first member uses the
# whitespace after the opening token; new members copy the whitespace of the
# previous member, never using that opening whitespace as a separator.
sub arrange {
   my ($records,$origins,$lead,$width)=@_;
   my $n=@$records;
   return [map +(defined($_->[0])? $records->[$_->[0]] : []),@$origins] unless $n;
   my $first=lead_ws($records->[0],$lead);
   my $sep=$n>1? lead_ws($records->[1],$lead) : $first;
   my @out;
   for my $i (0..$#$origins) {
      my ($j,$replaced)=@{$origins->[$i]};
      my $rec;
      if (defined $j) {
         $rec=$records->[$j];
         $rec=strip_value($rec) if $replaced;
         if (!$i && $j) { $rec=set_lead($rec,$lead,$first,$width) }
         elsif ($i && !$j) { $rec=set_lead($rec,$lead,$sep,$width) }
      }
      else {
         my $ws=!$i? $first : $i>1? lead_ws($out[$i-1],$lead) : $sep;
         $rec=set_lead(ws_only($i? $out[$i-1] : $records->[0]),$lead,$ws,$width);
      }
      push @out,$rec;
   }
   return \@out;
}
sub has_comments {
   my ($records,$outer)=@_;
   for my $gap (grep ref, map(defined($_)? @$_ : (),@$records),$outer? @{$outer}{qw(open close)} : ()) {
      for (my $i=1;$i<@$gap;$i+=2) { return 1 if defined $gap->[$i] }
   }
   return 0;
}
# True when a cloned value is interchangeable with the original for layout:
# the same reference or scalar, or a clean container from the same position.
sub same_origin {
   my ($a,$b)=@_;
   return !defined($b) if !defined $a;
   return 0 unless defined $b;
   if (ref $a) {
      return 0 unless ref $b;
      return 1 if refaddr($a)==refaddr($b);
      my $ta=ref($a) eq 'HASH'? tied(%$a) : ref($a) eq 'ARRAY'? tied(@$a) : undef;
      my $tb=ref($b) eq 'HASH'? tied(%$b) : ref($b) eq 'ARRAY'? tied(@$b) : undef;
      return $ta && $tb && ref($a) eq ref($b) && $ta->{doc} && $tb->{doc} && $ta->{doc}==$tb->{doc}
         && $ta->{open}==$tb->{open} && !$ta->{mod} && !$tb->{mod}? 1 : 0;
   }
   return !ref($b) && $a eq $b && JGraft::Util::type_mask($a)==JGraft::Util::type_mask($b)? 1 : 0;
}

# ---- Reconstruction from token positions ----

sub _line_indent {
   my ($text,$pos)=@_;
   my $start=$pos? rindex($$text,"\n",$pos-1)+1 : 0;
   # No capture group: capturing would copy the whole text on some Perls.
   pos($$text)=$start;
   $$text =~ /\G[ \t]*/gc;
   return substr($$text,$start,pos($$text)-$start);
}
# The text between non-comment tokens $p and $q (-1 and the token count denote
# the start and end of the text): (ws, comment token, ws, ..., ws).
sub _items {
   my ($doc,$p,$q)=@_;
   my ($t,$text)=($doc->{t},\$doc->{text});
   my $pos=$p<0? 0 : $t->[3*$p+1];
   my @items;
   for my $k ($p+1..$q-1) {
      push @items,substr($$text,$pos,$t->[3*$k]-$pos),$k;
      $pos=$t->[3*$k+1];
   }
   push @items,substr($$text,$pos,(3*$q<@$t? $t->[3*$q] : length $$text)-$pos);
   return \@items;
}
# Split a gap after a token: comments before the first one starting its own
# line trail the previous token; the rest lead the next.
sub _split {
   my $items=shift;
   my $k=1;
   while ($k<@$items) {
      last if $items->[$k-1] =~ /[\n\r]|\xe2\x80[\xa8\xa9]/;
      $k+=2;
   }
   return ([@$items[0..$k-2]],[@$items[$k-1..$#$items]]);
}
sub _classify {
   my ($w,$base)=@_;
   my $nl=rindex($w,"\n");
   return $w if $nl<0;
   my $last=substr($w,$nl+1);
   return $w unless $last =~ /\A[ \t]*\z/ && substr($last,0,length $base) eq $base;
   return "\0".substr($w,0,$nl+1).substr($last,length $base);
}
# Convert raw items into a stored gap; $$ml is set when whitespace has newlines.
sub _store {
   my ($doc,$items,$base,$ml)=@_;
   return undef unless @$items;
   my @out;
   for my $i (0..$#$items) {
      my $item=$items->[$i];
      if ($i%2) {
         my ($start,$end)=@{$doc->{t}}[3*$item,3*$item+1];
         my $c=substr($doc->{text},$start,$end-$start);
         utf8::decode($c) if $doc->{wide};
         $c="\0"._line_indent(\$doc->{text},$start)."\0$c" if $c =~ /\n/;
         push @out,$c;
         next;
      }
      utf8::decode($item) if $doc->{wide};
      $$ml=1 if $item =~ /\n/;
      push @out,$doc->{cw}? _classify($item,$base) : undef;
   }
   return @out%2? $out[-1] : undef unless $doc->{cc};
   return $out[0] if @out==1;
   return \@out;
}
sub _record {
   my $rec=shift;
   for (@$rec) { return $rec if defined($_) && (ref($_) || length($_)) }
   return undef;
}
# (outer, member records, members, value offsets) for the container whose
# opening token is $open. Members are [key, colon, value, value end, comma]
# token indices; value offsets map each value's byte offset to its member.
sub container_layout {
   my $tie=shift;
   my $doc=$tie->{doc} or return;
   return @{$doc->{cache}{$tie->{open}} ||= _build($doc,$tie->{open})};
}
sub _build {
   my ($doc,$open)=@_;
   my ($t,$text)=($doc->{t},\$doc->{text});
   my $close=$t->[3*$open+2];
   my $object=substr($$text,$t->[3*$open],1) eq '{';
   my $base=_line_indent($text,$t->[3*$open]);
   my @tokens;
   for (my $k=$open+1;$k<$close;$k++) {
      my $c=substr($$text,$t->[3*$k],1);
      next if $c eq '/';
      push @tokens,$k;
      $k=$t->[3*$k+2] if $c eq '{' || $c eq '[';
   }
   my (@members,%at);
   for (my $i=0;$i<@tokens;) {
      my @m=$object? ($tokens[$i],$tokens[$i+1]) : (undef,undef);
      $i+=2 if $object;
      my $v=$tokens[$i++];
      my $c=substr($$text,$t->[3*$v],1);
      push @m,$v,($c eq '{' || $c eq '['? $t->[3*$v+2] : $v);
      push @m,$i<@tokens? $tokens[$i++] : undef;
      $at{$t->[3*$v]}=@members;
      push @members,\@m;
   }
   my $ml=0;
   my %outer=(ws=>$doc->{cw},base=>$base);
   my @records;
   if (!@members) {
      # Comments in an empty container belong to its opening token.
      my $items=_items($doc,$open,$close);
      my $last=pop @$items;
      $outer{open}=_store($doc,$items,$base,\$ml);
      $outer{close}=_store($doc,[$last],$base,\$ml);
   }
   else {
      my ($trailing,$lead)=_split(_items($doc,$open,$members[0][$object? 0 : 2]));
      $outer{open}=_store($doc,$trailing,$base,\$ml);
      for my $j (0..$#members) {
         my ($k,$colon,$v,$end,$comma)=@{$members[$j]};
         my @rec;
         if ($object) {
            $rec[K_PRE]=_store($doc,$lead,$base,\$ml);
            $rec[C_PRE]=_store($doc,_items($doc,$k,$colon),$base,\$ml);
            ($trailing,$lead)=_split(_items($doc,$colon,$v));
            @rec[C_POST,V_PRE]=(_store($doc,$trailing,$base,\$ml),_store($doc,$lead,$base,\$ml));
         }
         else { $rec[V_PRE]=_store($doc,$lead,$base,\$ml) }
         my $next=$j<$#members? $members[$j+1][$object? 0 : 2] : $close;
         if (defined $comma) {
            $rec[M_PRE]=_store($doc,_items($doc,$end,$comma),$base,\$ml);
            ($trailing,$lead)=_split(_items($doc,$comma,$next));
            $outer{tc}=1 if $j==$#members;
         }
         else { ($trailing,$lead)=_split(_items($doc,$end,$next)) }
         $rec[POST]=_store($doc,$trailing,$base,\$ml);
         $outer{close}=_store($doc,$lead,$base,\$ml) if $j==$#members;
         $records[$j]=_record(\@rec);
      }
   }
   $outer{ml}=$ml;
   return [\%outer,\@records,\@members,\%at];
}
# [before, trailing after, leading after] for the document's root value.
sub document_layout {
   my $doc=shift;
   return $doc->{cache}{doc} ||= do {
      my ($first,$last)=@{$doc->{root}};
      my $ml;
      my ($trailing,$lead)=_split(_items($doc,$last,@{$doc->{t}}/3));
      [_store($doc,_items($doc,-1,$first),'',\$ml),_store($doc,$trailing,'',\$ml),_store($doc,$lead,'',\$ml)];
   };
}

=head1 DESCRIPTION

Private helpers shared by L<JGraft::JSON>, L<JGraft::JSON::Object>, and
L<JGraft::JSON::Array> for retained whitespace and comments. See the source
comments for the internal representation.

=for Pod::Coverage .*

=cut

1;
