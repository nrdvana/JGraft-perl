package JGraft::JSON::Number;
# VERSION
# ABSTRACT: JSON numeric token with lazy exact arithmetic
use strict;
use warnings;
use Carp 'croak';
use JGraft::Util 'to_rational';
our $EXEC;
# Strict JSON tokens, and the JSON5 numeric literal forms accepted with json5.
my $STRICT=qr/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/;
my $JSON5=qr/\A[+-]?(?:Infinity|NaN|0[xX][0-9a-fA-F]+
   |(?:(?:0|[1-9][0-9]*)(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\z/x;
my $INF=9**9**9;
use overload
   '""'=>sub { $_[0]{token} =~ $STRICT || $_[0]{token} =~ /[IN]/? $_[0]{token} : $_[0]->json_token },
   '0+'=>sub { $_[0]->_native },
   'bool'=>sub { _truth($_[0]{token}) },
   map({ my $op=$_; ($op=>sub { _operate($op,@_) }) } qw(+ - * / % <=>)),
   fallback=>1;

sub new {
   my ($class,$token,%options)=@_;
   $_ eq 'max_number_digits' || $_ eq 'number_overflow' || $_ eq 'json5'
      or croak "Unknown number option '$_'" for keys %options;
   my $json5=delete $options{json5};
   defined($token) && !ref($token) && ($token =~ $STRICT || $json5 && $token =~ $JSON5)
      or croak 'Invalid JSON number';
   my $s=bless {token=>$token,max_number_digits=>10000,number_overflow=>'reject',%options},$class;
   defined($s->{max_number_digits}) && !ref($s->{max_number_digits}) && $s->{max_number_digits} =~ /\A[0-9]+\z/
      or croak 'max_number_digits must be a nonnegative integer';
   defined($s->{number_overflow}) && $s->{number_overflow} =~ /\A(?:reject|native)\z/
      or croak 'number_overflow must be reject or native';
   return $s;
}
sub token { $_[0]{token} }
sub is_json { $_[0]{token} =~ $STRICT? 1 : 0 }
sub is_finite { $_[0]{token} =~ /[IN]/? 0 : 1 }
sub _truth {
   my $token=shift;
   return 1 if $token =~ /[IN]/;
   return $token =~ /\A[+-]?0[xX]0*[1-9a-fA-F]/? 1 : 0 if $token =~ /[xX]/;
   my ($mantissa)=split /[eE]/,$token,2;
   return $mantissa =~ /[1-9]/? 1 : 0;
}
sub _hex_digits {
   my $token=shift;
   return unless $token =~ /\A[+-]?0[xX]0*([0-9a-fA-F]*)\z/;
   return length $1;
}
# Decimal digits needed for a hexadecimal token, without converting it.
sub _hex_too_big {
   my $s=shift;
   my $digits=_hex_digits($s->{token});
   return defined($digits) && $s->{max_number_digits} && int($digits*1.21)+1>$s->{max_number_digits};
}
sub json_token {
   my $s=shift;
   my $token=$s->{token};
   return $token if $token =~ $STRICT;
   return $s->{json} if defined $s->{json};
   croak 'Cannot encode a non-finite JSON number' if $token =~ /[IN]/;
   my $sign=$token =~ s/\A([+-])//? $1 : '';
   $sign='' if $sign eq '+';
   if ($token =~ /\A0[xX]([0-9a-fA-F]+)\z/) {
      croak 'JSON number exceeds max_number_digits' if $s->_hex_too_big;
      my $hex=$1;
      my $exec=$EXEC;
      $exec->_reserve(1+length($hex)**2*.01,64+2*length($hex),0) if $exec;
      require Math::BigInt;
      local ($Math::BigInt::accuracy,$Math::BigInt::precision);
      return $s->{json}=$sign.Math::BigInt->new("0x$hex")->bstr;
   }
   my ($int,$frac,$exp)=$token =~ /\A([0-9]*)(?:\.([0-9]*))?(.*)\z/s;
   $int='0' unless length $int;
   return $s->{json}=$sign.$int.(defined($frac) && length($frac)? ".$frac" : '').$exp;
}
# A decimal spelling for size estimates; hexadecimal is sized, not converted.
sub _size_token {
   my $s=shift;
   my $token=$s->{token};
   return $token if $token =~ $STRICT || $token =~ /[IN]/;
   my $digits=_hex_digits($token);
   return defined($digits)? '9'x(int($digits*1.21)+1) : $s->json_token;
}
sub _native {
   my $s=shift;
   my $token=$s->{token};
   return 0+$token if $token =~ $STRICT;
   my $negative=$token =~ /\A-/;
   return $negative? -$INF : $INF if $token =~ /Infinity/;
   return $INF-$INF if $token =~ /NaN/;
   if ($s->_hex_too_big) {
      my ($hex)=$token =~ /([0-9a-fA-F]+)\z/;
      my $n=0;
      $n=$n*16+hex($_) for split //,$hex;
      return $negative? -$n : $n;
   }
   return 0+$s->json_token;
}
sub value {
   my $s=shift;
   return $s->{value}->copy if ref $s->{value};
   return $s->{value} if exists $s->{value};
   my $token=$s->{token};
   if ($token !~ $STRICT) {
      require Math::BigRat;
      if ($token =~ /[IN]/) {
         $s->{value}=$token =~ /NaN/? Math::BigRat->bnan : Math::BigRat->binf($token =~ /\A-/? "-" : "+");
         return $s->{value}->copy;
      }
      if ($s->_hex_too_big) {
         croak "JSON number exceeds max_number_digits" if $s->{number_overflow} eq "reject";
         return $s->{value}=$s->_native;
      }
      $token=$s->json_token;
   }
   my $scratch_base=$EXEC?$EXEC->{scratch_mem}:0;
   local $EXEC->{scratch_mem}=$scratch_base if $EXEC;
   $EXEC->_scratch_set($scratch_base,128+4*length($token)) if $EXEC;
   my ($mantissa,$exp)=split /[eE]/,$token,2;
   my $digits=length($mantissa);
   # Compare exponents as strings before coercing: an exponent can itself have
   # millions of digits, without allocating its mathematical number of zeroes.
   my $magnitude=defined($exp)?$exp:0;
   $magnitude =~ s/^[+-]//;
   $magnitude =~ s/^0+//;
   if ($s->{max_number_digits} && (length($magnitude)>9 || $digits+($magnitude||0)>$s->{max_number_digits})) {
      croak 'JSON number exceeds max_number_digits' if $s->{number_overflow} eq 'reject';
      $EXEC->_reserve(1+length($token)*.001,64,0) if $EXEC;
      return $s->{value}=0+$token;
   }
   if ($EXEC) {
      my $size=JGraft::Util::estimate_number_digits($s);
      $EXEC->_reserve(1+$size*$size*.01,256+16*$size,1);
   }
   require Math::BigRat;
   local ($Math::BigRat::accuracy,$Math::BigRat::precision);
   $s->{value}=Math::BigRat->new($token);
   return $s->{value}->copy;
}
sub _operate {
   my ($op,$a,$b,$swap)=@_;
   local ($Math::BigRat::accuracy,$Math::BigRat::precision);
   ($a,$b)=(to_rational($a),to_rational($b));
   ($a,$b)=($b,$a) if $swap;
   return $a->bcmp($b) if $op eq '<=>';
   return $a->badd($b) if $op eq '+';
   return $a->bsub($b) if $op eq '-';
   return $a->bmul($b) if $op eq '*';
   return scalar $a->bdiv($b) if $op eq '/';
   return $a->bsub($a->copy->bdiv($b)->bfloor->bmul($b));
}

=head1 SYNOPSIS

  my $number= JGraft::JSON::Number->new('0.100000000000000000001');
  my $rational= $number->value;
  my $hex= JGraft::JSON::Number->new('0x1F', json5 => 1);
  print $hex->json_token;   # 31

=head1 DESCRIPTION

Retains a validated JSON (or JSON5) numeric token. Encoding does not convert it to floating
point. C<value> lazily constructs an exact L<Math::BigRat>, returning a fresh copy
so arithmetic cannot modify the token or its cached value. Arithmetic overloads
also use exact rationals. Native numeric coercion necessarily uses Perl's numeric
range and precision. C<0 + $number> uses the exact addition
overload, just like other addition expressions; C<value> is the explicit accessor
for its rational value. During execution, creating its persistent cache is a
retained allocation; private conversion copies use their caller's workspace.

JSON5 tokens (hexadecimal, leading or trailing decimal points, explicit plus
signs, C<Infinity>, and C<NaN>) keep their spelling in C<token>. Stringification
and numeric conversion use the JSON spelling from C<json_token>; non-finite tokens
stringify as themselves and have infinite or NaN values. JGraft treats them as
non-finite numbers.

=constructor new

Accept a numeric token and optional C<json5> (accept JSON5 numeric literals),
C<max_number_digits> (default 10000; zero
disables the limit) and C<number_overflow> (C<reject>, or C<native>). The bound
includes the magnitude of the decimal exponent. Decoding and encoding the token
do not require expanding it, even when conversion would exceed this limit.

=method value

Return a fresh rational, or a native approximation when explicitly configured
with C<< number_overflow => 'native' >> and the conversion bound is exceeded.

=method token

Return the original numeric token.

=method json_token

Return a JSON spelling: the original token when it is valid JSON, otherwise an
equivalent decimal token (hexadecimal is converted exactly, subject to
C<max_number_digits>). Dies for C<Infinity> and C<NaN>.

=method is_json

True when the original token is valid JSON.

=method is_finite

False for C<Infinity> and C<NaN> tokens.

=cut

1;
