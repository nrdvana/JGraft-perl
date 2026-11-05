package JGraft::JSON::Number;
# VERSION
# ABSTRACT: JSON numeric token with lazy exact arithmetic
use strict;
use warnings;
use Carp 'croak';
use JGraft::Util 'to_rational';
use overload
   '""'=>sub { $_[0]{token} },
   '0+'=>sub { 0+$_[0]{token} },
   'bool'=>sub { $_[0]{token} =~ /[1-9]/ && $_[0]{token} !~ /\A-?0(?:\.0+)?(?:[eE].*)?\z/ },
   map({ my $op=$_; ($op=>sub { _operate($op,@_) }) } qw(+ - * / % <=>)),
   fallback=>1;

sub new {
   my ($class,$token,%options)=@_;
   $_ eq 'max_number_digits' || $_ eq 'number_overflow' or croak "Unknown number option '$_'" for keys %options;
   defined($token) && !ref($token) && $token =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/
      or croak 'Invalid JSON number';
   my $s=bless {token=>$token,max_number_digits=>10000,number_overflow=>'reject',%options},$class;
   defined($s->{max_number_digits}) && !ref($s->{max_number_digits}) && $s->{max_number_digits} =~ /\A[0-9]+\z/
      or croak 'max_number_digits must be a nonnegative integer';
   defined($s->{number_overflow}) && $s->{number_overflow} =~ /\A(?:reject|native)\z/
      or croak 'number_overflow must be reject or native';
   return $s;
}
sub token { $_[0]{token} }
sub value {
   my $s=shift;
   return $s->{value}->copy if ref $s->{value};
   return $s->{value} if exists $s->{value};
   my ($mantissa,$exp)=split /[eE]/,$s->{token},2;
   my $digits=length($mantissa);
   # Compare exponents as strings before coercing: an exponent can itself have
   # millions of digits, without allocating its mathematical number of zeroes.
   my $magnitude=defined($exp)?$exp:0;
   $magnitude =~ s/^[+-]//;
   $magnitude =~ s/^0+//;
   if ($s->{max_number_digits} && (length($magnitude)>9 || $digits+($magnitude||0)>$s->{max_number_digits})) {
      croak 'JSON number exceeds max_number_digits' if $s->{number_overflow} eq 'reject';
      return $s->{value}=0+$s->{token};
   }
   require Math::BigRat;
   local ($Math::BigRat::accuracy,$Math::BigRat::precision);
   $s->{value}=Math::BigRat->new($s->{token});
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

=head1 DESCRIPTION

Retains a validated JSON numeric token. Encoding does not convert it to floating
point. C<value> lazily constructs an exact L<Math::BigRat>, returning a fresh copy
so arithmetic cannot modify the token or its cached value. Arithmetic overloads
also use exact rationals. Native numeric coercion necessarily uses Perl's numeric
range and precision. C<0 + $number> uses the exact addition
overload, just like other addition expressions; C<value> is the explicit accessor
for its rational value.

=constructor new

Accept a numeric token and optional C<max_number_digits> (default 10000; zero
disables the limit) and C<number_overflow> (C<reject>, or C<native>). The bound
includes the magnitude of the decimal exponent. Decoding and encoding the token
do not require expanding it, even when conversion would exceed this limit.

=method value

Return a fresh rational, or a native approximation when explicitly configured
with C<< number_overflow => 'native' >> and the conversion bound is exceeded.

=method token

Return the original numeric token.

=cut

1;
