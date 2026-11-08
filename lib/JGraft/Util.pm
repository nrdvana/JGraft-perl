package JGraft::Util;
# VERSION
# ABSTRACT: Shared JGraft type predicates and numeric conversions
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util 'blessed';
use B ();
use JSON::PP ();
use constant {
   TYPE_NONE    => 0,
   TYPE_NULL    => 1,
   TYPE_BOOLEAN => 2,
   TYPE_NUMBER  => 4,
   TYPE_STRING  => 8,
   TYPE_ARRAY   => 16,
   TYPE_OBJECT  => 32,
   TYPE_DATE    => 64,
   TYPE_ANY     => 127,
};
our @EXPORT_OK= qw(type_mask is_finite is_integer is_expr is_action invalid_graft
   is_number_object estimate_number_digits to_native_number to_rational to_decimal_string);
our %EXPORT_TAGS=(types=>[qw(TYPE_NONE TYPE_NULL TYPE_BOOLEAN TYPE_NUMBER
   TYPE_STRING TYPE_ARRAY TYPE_OBJECT TYPE_DATE TYPE_ANY)]);
push @EXPORT_OK,@{$EXPORT_TAGS{types}};
our $_construction_context;

sub invalid_graft {
   my @context;
   for (my $frame=$_construction_context; $frame; $frame=$frame->{parent}) {
      push @context,{map {$_=>$frame->{$_}} grep $_ ne 'parent', keys %$frame};
   }
   require JGraft::Error;
   die JGraft::Error->new(code=>'INVALID_GRAFT',message=>join('',@_),context=>[reverse @context]);
}

sub type_mask {
   my $v= shift;
   return TYPE_NULL unless defined $v;
   return TYPE_BOOLEAN if JSON::PP::is_bool($v);
   return $v->returns if is_expr($v);
   if (blessed($v)) {
      return TYPE_STRING if $v->isa('JGraft::JSON::String');
      return TYPE_NUMBER if $v->isa('JGraft::JSON::Number') || $v->isa('Math::BigRat')
         || $v->isa('Math::BigInt') || $v->isa('Math::BigFloat');
   }
   return TYPE_DATE if blessed($v) && ($v->isa('JGraft::Date') || $v->isa('Time::Piece') || $v->isa('DateTime'));
   return TYPE_ARRAY if ref $v eq 'ARRAY';
   return TYPE_OBJECT if ref $v eq 'HASH';
   return TYPE_NONE if ref $v;
   my $flags= B::svref_2object(\$v)->FLAGS;
   return ($flags & (B::SVp_IOK() | B::SVp_NOK())) && !($flags & B::SVp_POK())? TYPE_NUMBER : TYPE_STRING;
}
sub is_finite {
   my $v= shift;
   return 0 if type_mask($v) != TYPE_NUMBER;
   return 1 if blessed($v) && $v->isa('JGraft::JSON::Number');
   return !$v->is_nan && !$v->is_inf if blessed($v);
   return ($v - $v) == 0;
}
sub is_integer {
   my $v=shift;
   return 0 unless is_finite($v);
   if (blessed($v) && $v->isa('JGraft::JSON::Number')) {
      my ($m,$e)=split /[eE]/,$v->token,2;
      return 1 if $m !~ /[1-9]/;
      $e=0 unless defined $e;
      my $places=$m =~ /\.([0-9]+)/?length($1):0;
      my ($zeros)=$m =~ /(0*)\z/;
      return $e>= $places-length($zeros);
   }
   return $v->is_int if blessed($v);
   return $v == int($v);
}
sub is_expr { blessed($_[0]) && $_[0]->isa('JGraft::Expr') }
sub is_action { blessed($_[0]) && $_[0]->isa('JGraft::Action') }

sub is_number_object {
   blessed($_[0]) && ($_[0]->isa('JGraft::JSON::Number') || $_[0]->isa('Math::BigRat')
      || $_[0]->isa('Math::BigInt') || $_[0]->isa('Math::BigFloat'));
}
# Math's backends expose digit counts without decimal strings. Keep knowledge
# of its stable _n/_d and _m/_e representation here, including old core Math
# versions; no callers need to copy numerator/mantissa objects just to size them.
# Return compact spelling length and the conservative expanded conversion size.
sub _number_sizes {
   my $v=shift;
   if (ref($v) && !$v->isa('JGraft::JSON::Number')) {
      if ($v->{sign} ne '+' && $v->{sign} ne '-') {
         my $size=length($v->{sign})-($v->{sign} eq '+inf'?1:0);
         return ($size,$size);
      }
      my $sign=$v->{sign} eq '-'?1:0;
      # BigRat deliberately reports false for isa(BigFloat/BigInt), despite
      # its implementation inheritance. Classify it before either other type.
      if ($v->isa('Math::BigRat')) {
         my $class=ref($v);
         my $lib=$class->config('lib');
         my $size=$sign+$lib->_len($v->{_n});
         $size+=1+$lib->_len($v->{_d}) unless $lib->_is_one($v->{_d});
         return ($size,$size);
      }
      if ($v->isa('Math::BigFloat')) {
         my $class=ref($v);
         my $lib=$class->config('lib');
         my $digits=$lib->_len($v->{_e});
         my $size=$sign+$lib->_len($v->{_m})+2+$digits;
         my $exponent=$digits>9?1e100:$lib->_num($v->{_e});
         return ($size,$size+$exponent);
      }
      my $size=$sign+scalar $v->length;
      return ($size,$size);
   }
   my $text=ref($v)?$v->token:"$v";
   my $size=length($text);
   my $expanded=$size;
   if ($text =~ /[eE][+-]?[0-9]+\z/) {
      pos($text)=$-[0]+1;
      $text =~ /\G[+-]?0*/gc;
      my $digits=$size-pos($text);
      $expanded+=$digits>9?1e100:$digits?0+substr($text,-$digits):0;
   }
   if (ref($v) && $v->isa('JGraft::JSON::Number') && $v->{number_overflow} eq 'native'
      && $v->{max_number_digits} && $expanded>$v->{max_number_digits}) {
      # Native approximation avoids the original exponent expansion, but a
      # finite native value may still expand to hundreds of rational digits.
      my $native=0+$text;
      my $native_size=estimate_number_digits($native);
      $expanded=$native_size>$size?$native_size:$size;
   }
   return ($size,$expanded);
}
sub estimate_number_digits { (_number_sizes($_[0]))[1] }
# Execution promotes exact arithmetic operands to private BigRat copies. Read
# their normalized representation without allocating numerator/denominator copies.
# Native operands here are the fold's initial zero/one (or a library downgrade).
# Return numerator/denominator digits, integer/negative/zero/absolute-one flags,
# and spelling length. The bounded bookkeeping is leaf-call scratch.
sub _rational_shape {
   my ($v,$lib)=@_;
   unless (ref $v) {
      return (1,1,1,$v<0?1:0,$v==0?1:0,$v==1 || $v==-1?1:0,$v<0?2:1) if $v==0 || $v==1 || $v==-1;
      my $size=estimate_number_digits($v);
      $size=32 if $size<32;
      return ($size,$size,is_integer($v)?1:0,$v<0?1:0,0,0,2*$size+2);
   }
   unless ($v->isa('Math::BigRat')) {
      my $size=estimate_number_digits($v);
      my $negative=$v->is_neg?1:0;
      return ($size,$size,$v->is_int?1:0,$negative,$v->is_zero?1:0,0,2*$size+2);
   }
   my $n=$lib->_len($v->{_n});
   my $d=$lib->_len($v->{_d});
   my $integer=$lib->_is_one($v->{_d})?1:0;
   my $negative=$v->{sign} eq '-'?1:0;
   return ($n,$d,$integer,$negative,$lib->_is_zero($v->{_n})?1:0,
      $integer && $lib->_is_one($v->{_n})?1:0,$n+$negative+($integer?0:1+$d));
}
sub _rational_same_magnitude {
   my ($a,$b,$lib)=@_;
   return ref($a) && ref($b) && $a->isa('Math::BigRat') && $b->isa('Math::BigRat')
      && !$lib->_acmp($a->{_n},$b->{_n}) && !$lib->_acmp($a->{_d},$b->{_d});
}
sub to_native_number {
   my $v=shift;
   return $v unless ref $v;
   return 0+$v->token if $v->isa('JGraft::JSON::Number');
   return 0+$v->numify;
}
sub to_rational {
   my $v=shift;
   $v=$v->value if blessed($v) && $v->isa('JGraft::JSON::Number');
   require Math::BigRat;
   local ($Math::BigRat::accuracy,$Math::BigRat::precision);
   return Math::BigRat->new($v?1:0) if JSON::PP::is_bool($v);
   if (blessed($v) && $v->isa('Math::BigRat')) {
      my $out=$v->copy;
      $out->accuracy(undef); $out->precision(undef);
      return $out;
   }
   if (blessed($v)) { return Math::BigRat->new($v->isa('Math::BigFloat')?$v->bsstr:$v->bstr) }
   # JSON's decimal spelling avoids losing IV/UV precision through an NV.
   my $token=JSON::PP->new->allow_nonref->encode($v);
   # Perl supplies the increment/decrement operand as a string on some versions.
   $token=$v if $token =~ /^"/ && $v =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/;
   return Math::BigRat->new($token);
}
sub to_decimal_string {
   my ($v,$limit)=@_;
   require Math::BigInt;
   $limit=10000 unless defined $limit;
   local ($Math::BigRat::accuracy,$Math::BigRat::precision,$Math::BigInt::accuracy,$Math::BigInt::precision);
   return $v->token if blessed($v) && $v->isa('JGraft::JSON::Number');
   $limit && estimate_number_digits($v)>$limit and die "JSON decimal exceeds max_number_digits\n";
   my $r=to_rational($v);
   $r->is_nan || $r->is_inf and die "Cannot encode a non-finite JSON number\n";
   my $n=$r->numerator->copy;
   my $d=$r->denominator->copy;
   my ($twos,$fives)=(0,0);
   while ($d->copy->bmod(2)->is_zero) {
      $d->bdiv(2); ++$twos;
      $limit && $twos>$limit and die "JSON decimal exceeds max_number_digits\n";
   }
   while ($d->copy->bmod(5)->is_zero) {
      $d->bdiv(5); ++$fives;
      $limit && $fives>$limit and die "JSON decimal exceeds max_number_digits\n";
   }
   $d->is_one or die "Rational has no finite JSON decimal representation\n";
   my $places=$twos>$fives?$twos:$fives;
   $n->bmul(Math::BigInt->new(2)->bpow($places-$twos)) if $places>$twos;
   $n->bmul(Math::BigInt->new(5)->bpow($places-$fives)) if $places>$fives;
   my $text=$n->bstr;
   $limit && length($text)>$limit+1 and die "JSON decimal exceeds max_number_digits\n";
   return $text unless $places;
   my $sign=$text =~ s/^-//?'-':'';
   $text=('0'x($places+1-length($text))).$text if length($text)<=$places;
   substr($text,length($text)-$places,0)='.';
   $text =~ s/0+\z//;
   $text =~ s/\.\z//;
   return $sign.$text;
}

=head1 DESCRIPTION

Optional exports shared by the node constructors and executor. Numeric predicates
inspect copies of scalar values, preserving numeric/string distinctions in input.
Numeric conversion helpers also support Math::BigInt, Math::BigFloat,
Math::BigRat, and L<JGraft::JSON::Number>. Math modules are loaded on demand.

=head1 TYPE CONSTANTS

  use JGraft::Util qw(:types type_mask);
  my $allowed= TYPE_NULL | TYPE_NUMBER;

The C<:types> export tag supplies these Perl constants; each may also be imported
individually. Combine type bits with C<|>. Their numeric values are unchanged:

  TYPE_NONE       0    No possible result, or an unrecognized reference
  TYPE_NULL       1
  TYPE_BOOLEAN    2
  TYPE_NUMBER     4
  TYPE_STRING     8
  TYPE_ARRAY     16
  TYPE_OBJECT    32
  TYPE_DATE      64
  TYPE_ANY      127    All supported type bits

=for Pod::Coverage TYPE_[A-Z]+

=function invalid_graft

  invalid_graft('Invalid operand: ', $description);

Throw a L<JGraft::Error> with code C<INVALID_GRAFT>, concatenating the message
arguments. Captures the current construction context and a text-only Carp stack
trace. Context is empty when called outside node construction. No exports are
enabled by default.

=function type_mask

Return the JSON type bitmask: null=1, boolean=2, number=4, string=8, array=16,
object=32. Math::BigInt, Math::BigFloat, Math::BigRat, and JGraft::JSON::Number
return number; JGraft::JSON::String returns string. An expression object returns
its possible result types (including date=64); other references return zero.
This does not validate container contents.
Use the named L</TYPE CONSTANTS> when checking or combining these bits.

=function is_finite

True for a finite numeric scalar, Math::BigInt, Math::BigFloat, Math::BigRat, or
JGraft::JSON::Number. Strings, booleans, other objects, infinity, and NaN return
false without numeric coercion of strings. JSON tokens are mathematically finite
even when they exceed the configured conversion bound or native numeric range.

=function is_integer

True for a finite numeric scalar with no fractional part.

=function is_number_object

True for a Math::BigInt, Math::BigFloat, Math::BigRat, or JGraft::JSON::Number
object, including subclasses. Native numeric scalars return false; use
C<type_mask> to recognize all supported numeric values. Does not test finiteness.

=function to_rational

  use JGraft::Util 'to_rational';
  my $rational= to_rational($number);

Return a fresh Math::BigRat for a native number or supported numeric object,
preserving its decimal value without mutating the input. Native numbers use
their JSON decimal spelling, avoiding conversion of exact IV/UV integers through
floating point. JSON::Number applies its configured lazy conversion policy.
Decimal numeric strings are also accepted; booleans become zero or one.
The returned object has no accuracy or precision limit, independent of global
Math::BigRat rounding settings. Conversion errors from JSON::Number propagate.

=function to_native_number

Convert a supported numeric object to a native Perl number. Native scalar inputs
pass through unchanged. Conversion may lose precision or exceed Perl's numeric
range; it deliberately bypasses JSON::Number's rational conversion bound.

=function to_decimal_string

  my $text= to_decimal_string($number, $max_digits);

Return an exact JSON numeric token. A JSON::Number returns its original token,
including exponent spelling and negative zero. Other numbers are converted to
rationals and emitted as finite decimal strings. Dies on infinity, NaN, a
nonterminating decimal expansion, or an exceeded digit bound. The bound defaults
to 10000; zero disables it. Original JSON::Number tokens bypass this bound because
they do not require expansion. Input objects are never modified.

=function estimate_number_digits

Estimate numeric conversion work from a number's spelling length plus decimal
exponent magnitude. Math values use digit counts from their existing representation,
without constructing decimal spellings or copying numerator/mantissa values.
Compact Math::BigFloat and JSON::Number exponents are not expanded. This is a
conservative resource-accounting estimate, not an exact count
of significant digits. Exponents longer than nine digits use a sentinel of
C<1e100>. JSON::Number values configured to fall back to native conversion use
the larger of their token length and their native approximation's estimate when
their conversion bound is exceeded.

=function is_expr

True for a JGraft expression object.

=function is_action

True for a JGraft action object.

=cut

1;
