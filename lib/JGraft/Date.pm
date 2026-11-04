package JGraft::Date;
# VERSION
# ABSTRACT: Immutable Gregorian dates, datetimes, and fixed-offset timestamps
use strict;
use warnings;
use Carp 'croak';
use Hash::Util 'lock_hash';
use Scalar::Util 'blessed';
use POSIX 'floor';
use JSON::PP ();
use JGraft::Util qw(:types type_mask is_finite is_integer);

sub new {
   my $class=shift;
   @_==1 || @_ % 2==0 or croak 'Expected a date value or name/value fields';
   my $value=@_==1? $_[0] : {@_};
   return $value if blessed($value) && $value->isa(__PACKAGE__);
   my (%v,$fraction);
   if (blessed($value) && $value->isa('Time::Piece')) {
      %v=(year=>$value->year,month=>$value->mon,day=>$value->mday,
         hour=>$value->hour,minute=>$value->min,second=>$value->sec,tz_offset=>0+$value->tzoffset/60);
      is_integer($v{tz_offset}) or croak 'UNSUPPORTED_GRAFT: Sub-minute timezone offset';
   }
   elsif (blessed($value) && $value->isa('DateTime')) {
      $value->is_finite or croak 'UNSUPPORTED_GRAFT: Infinite DateTime';
      %v=(year=>$value->year,month=>$value->month,day=>$value->day,
         hour=>$value->hour,minute=>$value->minute,second=>$value->second);
      $v{tz_offset}=$value->offset/60 unless $value->time_zone->is_floating;
      !exists($v{tz_offset}) || is_integer($v{tz_offset}) or croak 'UNSUPPORTED_GRAFT: Sub-minute timezone offset';
      $fraction=sprintf('%09d',$value->nanosecond);
   }
   elsif (ref($value) eq 'HASH') { %v=%$value }
   elsif (type_mask($value)==TYPE_STRING) {
      my ($date,$clock,$zone);
      $value =~ /\A([+-]?[0-9]{4,}-[0-9]{2}-[0-9]{2}|[0-9]{8})(?:[T ]([0-9]{2}:?[0-9]{2}:?[0-9]{2}(?:[.,][0-9]+)?)(Z|[+\x{2212}-][0-9]{2}(?::?[0-9]{2})?)?)?\z/
         or croak 'Invalid ISO8601 date';
      ($date,$clock,$zone)=($1,$2,$3);
      if ($date =~ /\A([+-]?[0-9]+)-([0-9]{2})-([0-9]{2})\z/) {
         my ($year,$month,$day)=($1,$2,$3);
         (my $digits=$year) =~ s/\A[+-]?0*//;
         length($digits)<=13 or croak 'UNSUPPORTED_GRAFT: Year exceeds supported calendar range';
         @v{qw(year month day)}=map 0+$_,($year,$month,$day);
      }
      else { @v{qw(year month day)}=map 0+$_,unpack('A4A2A2',$date) }
      if (defined $clock) {
         $clock =~ /\A([0-9]{2}):?([0-9]{2}):?([0-9]{2})(?:[.,]([0-9]+))?\z/;
         @v{qw(hour minute second)}=map 0+$_,($1,$2,$3); $fraction=$4;
      }
      if (defined $zone) {
         my $offset=0;
         if ($zone ne 'Z') {
            $zone =~ /\A([+\x{2212}-])([0-9]{2})(?::?([0-9]{2}))?\z/;
            my ($sign,$hours,$minutes)=($1,0+$2,defined($3)?0+$3:0);
            $hours<24 && $minutes<60 or croak 'Invalid timezone offset';
            $sign eq '+' || $hours || $minutes or croak 'Negative zero timezone offset is not ISO8601';
            $offset=($sign eq '+'?1:-1)*(60*$hours+$minutes);
         }
         $v{tz_offset}=$offset;
      }
   }
   else { croak 'Invalid date input' }
   my %allowed=map {$_=>1} qw(year month day hour minute second tz_offset);
   exists($v{year}) or croak 'Date requires year';
   $allowed{$_} or croak "Unknown date field $_" for keys %v;
   my $type=exists($v{tz_offset})?'timestamp' : grep(exists($v{$_}),qw(hour minute second))?'datetime':'date';
   $v{month}=1 unless exists $v{month}; $v{day}=1 unless exists $v{day};
   if ($type ne 'date') { $v{$_}=0 for grep !exists($v{$_}),qw(hour minute second) }
   for my $key (keys %v) {
      is_finite($v{$key}) && ($key eq 'second' || is_integer($v{$key})) or croak "Invalid date field $key";
   }
   abs($v{year})<=1000000000000 or croak 'UNSUPPORTED_GRAFT: Year exceeds supported calendar range';
   $v{month}>=1 && $v{month}<=12 or croak 'Invalid month';
   my $days=(31,28,31,30,31,30,31,31,30,31,30,31)[$v{month}-1];
   ++$days if $v{month}==2 && _leap($v{year});
   $v{day}>=1 && $v{day}<=$days or croak 'Invalid day';
   if ($type ne 'date') {
      $v{hour}>=0 && $v{hour}<24 && $v{minute}>=0 && $v{minute}<60 && $v{second}>=0 && $v{second}<61
         or croak 'Invalid clock field';
      unless (defined $fraction) {
         # Object inputs have host numeric precision. Expand exponents before
         # separating the fractional part; ISO input retains its original digits.
         $fraction=_fraction($v{second});
      }
      $v{second}=int($v{second});
      $fraction='' unless defined $fraction;
      $fraction =~ s/0+\z//;
   }
   is_integer($v{tz_offset}) && abs($v{tz_offset})<1440 or croak 'Invalid timezone offset' if exists $v{tz_offset};
   my $self=bless {%v,type=>$type,fraction=>defined($fraction)?$fraction:''},$class;
   lock_hash(%$self);
   return $self;
}
sub _fraction {
   my $seconds=JSON::PP->new->allow_nonref->encode($_[0]);
   0+$seconds==$_[0] or croak 'UNSUPPORTED_GRAFT: Numeric seconds cannot round trip through JSON';
   if ($seconds =~ /\A([0-9]+)(?:\.([0-9]*))?[eE]([+-]?[0-9]+)\z/) {
      my ($digits,$point)=($1.(defined($2)?$2:''),length($1)+$3);
      $seconds=$point<=0? '0.'.('0'x(-$point)).$digits
         : $point>=length($digits)? $digits.('0'x($point-length($digits)))
         : substr($digits,0,$point).'.'.substr($digits,$point);
   }
   my ($fraction)=$seconds =~ /\.([0-9]+)/;
   $fraction='' unless defined $fraction;
   $fraction =~ s/0+\z//;
   return $fraction;
}
sub _leap { $_[0]%4==0 && ($_[0]%100!=0 || $_[0]%400==0) }
sub type { $_[0]{type} }
sub year { $_[0]{year} }
sub month { $_[0]{month} }
sub day { $_[0]{day} }
sub hour { exists($_[0]{hour})? $_[0]{hour}:undef }
sub minute { exists($_[0]{minute})? $_[0]{minute}:undef }
sub second {
   my $self=shift;
   return unless exists $self->{second};
   my $number=$self->{second}+($self->{fraction} eq ''?0:0+('0.'.$self->{fraction}));
   int($number)==$self->{second} && _fraction($number) eq $self->{fraction}
      or croak 'UNSUPPORTED_GRAFT: Fractional seconds exceed host numeric precision';
   return $number;
}

sub tz_offset { exists($_[0]{tz_offset})? $_[0]{tz_offset}:undef }
sub fraction { $_[0]{fraction} }
sub fields {
   my $self=shift;
   return {map {$_=>$_ eq 'second'? $self->second : $self->{$_}}
      grep exists($self->{$_}),qw(year month day hour minute second tz_offset)};
}
sub _has { $_[1] =~ /\A(?:year|month|day|hour|minute|second|tz_offset)\z/ && exists $_[0]{$_[1]} }
sub _get { $_[1] eq 'second'? $_[0]->second : $_[0]{$_[1]} }
sub to_iso8601 {
   my $self=shift;
   my $year=$self->{year}<0? '-'.sprintf('%04.0f',-$self->{year}) : sprintf('%04.0f',$self->{year});
   my $out=sprintf('%s-%02d-%02d',$year,$self->{month},$self->{day});
   if ($self->{type} ne 'date') {
      $out.=sprintf('%s%02d:%02d:%02d',$self->{type} eq 'datetime'?' ':'T',@{$self}{qw(hour minute second)});
      $out.='.'.$self->{fraction} if length $self->{fraction};
   }
   if ($self->{type} eq 'timestamp') {
      my $tz=$self->{tz_offset};
      $out.=$tz? sprintf('%s%02d%02d',$tz<0?'-':'+',int(abs($tz)/60),abs($tz)%60) : 'Z';
   }
   return $out;
}
# Days from a March-based Gregorian origin. This avoids libc epoch limits and
# leaves seconds separate so a leap second never aliases the following minute.
sub _day_number {
   my $self=shift;
   my ($y,$m)=@{$self}{qw(year month)};
   --$y if $m<=2;
   $m+=$m>2?-3:9;
   return 365*$y+floor($y/4)-floor($y/100)+floor($y/400)+floor((153*$m+2)/5)+$self->{day}-1;
}
sub _compare {
   my ($a,$b)=@_;
   $a->{type} eq $b->{type} or croak 'Cannot compare different date precisions';
   my ($ad,$bd)=($a->_day_number,$b->_day_number);
   my ($am,$bm)=(0,0);
   if ($a->{type} ne 'date') {
      $am=60*$a->{hour}+$a->{minute}; $bm=60*$b->{hour}+$b->{minute};
      if ($a->{type} eq 'timestamp') { $am-=$a->{tz_offset}; $bm-=$b->{tz_offset} }
      my ($ao,$bo)=(floor($am/1440),floor($bm/1440));
      $ad+=$ao; $bd+=$bo; $am-=1440*$ao; $bm-=1440*$bo;
   }
   my $c=($ad<=>$bd) || ($am<=>$bm);
   return $c if $c || $a->{type} eq 'date';
   $c=$a->{second}<=>$b->{second}; return $c if $c;
   # Trailing zeros have already been removed; lexicographic comparison of
   # the remaining digits has exactly the same order as decimal fractions.
   return $a->{fraction} cmp $b->{fraction};
}
sub to_time_piece {
   my $self=shift;
   require Time::Piece;
   length($self->{fraction}) || (exists($self->{second}) && $self->{second}==60)
      and croak 'UNSUPPORTED_GRAFT: Time::Piece cannot preserve fractional or leap seconds';
   my $seconds=($self->_day_number-__PACKAGE__->new('1970-01-01')->_day_number)*86400;
   $seconds+=60*(60*$self->{hour}+$self->{minute})+$self->{second} if $self->{type} ne 'date';
   $seconds-=60*$self->{tz_offset} if $self->{type} eq 'timestamp';
   abs($seconds)<=9007199254740991 or croak 'UNSUPPORTED_GRAFT: Time::Piece epoch would lose integer precision';
   my $out=eval { Time::Piece::gmtime($seconds) };
   blessed($out) or croak 'UNSUPPORTED_GRAFT: Time::Piece cannot represent this date';
   $out->epoch==$seconds or croak 'UNSUPPORTED_GRAFT: Time::Piece lost date precision';
   return $out;
}
sub to_datetime {
   my $self=shift;
   require DateTime;
   length($self->{fraction})>9 and croak 'UNSUPPORTED_GRAFT: DateTime cannot preserve more than nine fractional digits';
   my %args=%{$self->fields};
   delete $args{tz_offset}; $args{second}=$self->{type} eq 'date'?0:$self->{second};
   $args{nanosecond}=0+substr($self->{fraction}.'000000000',0,9);
   $args{time_zone}=$self->{type} eq 'timestamp'? ($self->{tz_offset}?sprintf('%s%02d%02d',$self->{tz_offset}<0?'-':'+',int(abs($self->{tz_offset})/60),abs($self->{tz_offset})%60):'UTC'):'floating';
   my $out=eval { DateTime->new(%args) };
   $out or croak 'UNSUPPORTED_GRAFT: DateTime cannot represent this date';
   return $out;
}
sub format {
   my ($self,$format)=@_;
   return $format->($self) if ref($format) eq 'CODE';
   return $self->to_iso8601 if !defined($format) || $format eq 'iso8601';
   return $self->to_time_piece if $format eq 'Time::Piece';
   return $self->to_datetime if $format eq 'DateTime';
   croak 'Unknown date format';
}

1;

=head1 SYNOPSIS

  my $date = JGraft::Date->new('2024-02-29T12:30:00.125+0530');
  my $text = $date->to_iso8601;
  my $native = $date->format('DateTime');

=head1 DESCRIPTION

Immutable Gregorian date, datetime, and fixed-offset timestamp values. The class
uses integer calendar calculations rather than host epochs. Leap seconds remain
separate from minutes; ISO fractional seconds retain their decimal digits. Years
from -1,000,000,000,000 through 1,000,000,000,000 are supported. Gregorian calendar
rules apply throughout this range, including year zero.

=constructor new

  JGraft::Date->new($iso8601_string);
  JGraft::Date->new(\%fields);
  JGraft::Date->new(year => 2024, month => 2, day => 29);
  JGraft::Date->new($date_or_native_object);

Accepts the CASTDATE formats and fields described by the JGraft specification.
Time fields select datetime precision; C<tz_offset> selects timestamp precision.
Timezone offsets are integer minutes with magnitude below 1440. Native
Time::Piece and DateTime values are imported as snapshots; named timezones become
fixed offsets. Floating DateTime values become datetimes. Sub-minute offsets and
infinite dates are unsupported. An existing JGraft::Date passes through unchanged.

Invalid input throws an exception. Host representation limits are identified by
an C<UNSUPPORTED_GRAFT> prefix; execution converts these into its diagnostic type.
Objects and their fields cannot be modified after construction.

=attribute type

C<date>, C<datetime>, or C<timestamp>.

=attribute year

The signed Gregorian year.

=attribute month

Month from 1 through 12.

=attribute day

Day of the month, validated against the Gregorian calendar.

=attribute hour

Hour from 0 through 23, or undef for a date.

=attribute minute

Minute from 0 through 59, or undef for a date.

=attribute second

Numeric seconds, including a fractional part and possible leap second, or undef
for a date. Throws UNSUPPORTED_GRAFT if converting the exact stored fraction to
a host number would lose decimal precision. Formatting and date comparison can
still use those exact digits without converting them to a number.

=attribute tz_offset

Integer minutes east of UTC, or undef for a date/datetime.

=attribute fraction

Fractional-second digits without a decimal point. Trailing zeros are removed;
the empty string represents no fraction. Digits are preserved independently of
host floating-point precision.

=method fields

Returns a new hashref containing the applicable public calendar fields. Its
C<second> field uses the numeric accessor and its precision checks.

=method to_iso8601

Returns C<yyyy-mm-dd>, C<yyyy-mm-dd hh:mm:ss>, or
C<yyyy-mm-ddThh:mm:ssZ>/C<yyyy-mm-ddThh:mm:ss+hhmm>. Fractions and expanded years
are preserved. This method does not require Time::Piece or DateTime.

=method to_time_piece

Lazily loads Time::Piece and returns a UTC object. Timestamp offsets are applied
to preserve the instant; dates and floating datetimes are interpreted at UTC.
Time::Piece cannot preserve fractional or leap seconds, so those conversions
throw UNSUPPORTED_GRAFT. The host's epoch range may impose additional limits.
Native objects cannot retain JGraft's date-only/floating precision distinction.

=method to_datetime

Lazily loads the optional DateTime module. Returns a floating DateTime for dates
and datetimes, or a fixed-offset DateTime for timestamps. Nanoseconds are retained;
more than nine fractional digits and dates DateTime cannot represent throw
UNSUPPORTED_GRAFT. Date-only values become midnight floating datetimes.
The library has no mandatory DateTime dependency.

=method format

  $date->format;                  # ISO8601
  $date->format('iso8601');
  $date->format('Time::Piece');
  $date->format('DateTime');
  $date->format(sub { my ($date) = @_; ... });

Selects one of the built-in formatters or calls a callback with this immutable
object. The callback result is returned unchanged and callback exceptions propagate.
