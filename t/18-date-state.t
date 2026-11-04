use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Date;
use JGraft::Exec;
use Scalar::Util 'refaddr';
use Storable 'dclone';
use JSON::PP ();

my $date=JGraft::Date->new('2024-02-29T23:59:60.1234567890123456789+0530');
is($date->type,'timestamp','timestamp retains precision kind');
is($date->fraction,'1234567890123456789','ISO fractions retain all decimal digits');
is($date->to_iso8601,'2024-02-29T23:59:60.1234567890123456789+0530','ISO formatting preserves leap and fractional seconds');
is(refaddr(JGraft::Date->new($date)),refaddr($date),'casting an internal date preserves identity');
ok(!eval {$date->{year}=2025;1},'date fields are immutable');
ok(!eval {$date->{fraction}='';1},'fractional digits are immutable');
ok(!eval {delete $date->{month};1},'date fields cannot be removed');
ok(!eval {$date->{new}=1;1},'date fields cannot be added');
my $cloned=dclone($date);
ok(!eval {$cloned->{year}=2025;1},'Storable retains immutability');
is($cloned->to_iso8601,$date->to_iso8601,'Storable retains fractional precision');
for my $year (0,1,4,99,100,400,1583,1600,1900,2000,10000,-400) {
   my $d=JGraft::Date->new(year=>$year,month=>3,day=>1);
   is(JGraft::Date->new($d->to_iso8601)->fields,$d->fields,"year $year round trips without the libc 0-99 trap");
}
for my $invalid ('2023-02-29','1900-02-29','2024-04-31','2024-01-01T24:00:00','2024-01-01T00:00:61',
   '2024-01-01T00:00:00-00','2024-01-01T00:00:00+2400',' 2024-01-01','2024-01-01junk') {
   ok(!eval {JGraft::Date->new($invalid);1},"reject invalid date $invalid");
}
for my $input ({year=>2024,second=>1e-9},{year=>2024,second=>60.5},{year=>2024,second=>0.1}) {
   my $d=JGraft::Date->new($input);
   is(JGraft::Date->new($d->to_iso8601)->fields,$d->fields,'object fraction and ISO text agree');
}
my $a=JGraft::Date->new('2024-03-01T00:30:60.5+0100');
my $b=JGraft::Date->new('2024-02-29T23:30:60.5Z');
is($a->_compare($b),0,'offset normalization preserves leap seconds across leap day');
ok(JGraft::Date->new('2024-02-29T23:30:60.5Z')->_compare(JGraft::Date->new('2024-02-29T23:31:00Z'))<0,
   'leap second precedes following minute');
ok(JGraft::Date->new('2024-01-01T00:00:00.1234567890123456789Z')->_compare(
   JGraft::Date->new('2024-01-01T00:00:00.123456789012345679Z'))<0,'comparison preserves sub-native fractional distinctions');
is(jgexec(COPY(LESS(CASTDATE('2024-01-01'),CASTDATE('2024-01-02')),NODE()),undef),JSON::PP::true,'LESS compares dates');
is(jgexec(COPY(LESSEQ(CASTDATE($a),CASTDATE($b)),NODE()),undef),JSON::PP::true,'LESSEQ compares normalized instants');
is(jgexec(COPY(NONE(LESS(CASTDATE('2024-01-01'),CASTDATE('2024-01-01T00:00:00'))),NODE()),undef),
   JSON::PP::true,'different date precisions are a failed comparison probe');

my $native=JGraft::Date->new('2024-01-02T03:04:05+0200');
my $data={date=>$native,untouched=>['keep']};
my $exec=JGraft::Exec->new(jgraft=>COPY(NODE('date','year'),'year'),undo=>1);
$exec->apply($data);
is($exec->output->{year},2024,'NODE reads virtual date fields');
is(refaddr($exec->output->{date}),refaddr($native),'untouched dates remain shared immutable values');
is(refaddr($exec->output->{untouched}),refaddr($data->{untouched}),'unrelated subtrees remain shared');
for my $graft (COPY(2025,NODE('date','year')),MOVE(NODE('date','year'),NODE('year')),
   MOVE(NODE('year'),NODE('date','year'))) {
   $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   $exec->apply({date=>$native,year=>2025});
   is($exec->error,'INVALID_TARGET','date fields are read-only for COPY and MOVE');
   is($native->year,2024,'attempted date mutation preserves original');
}
my $notation=COPY($native,NODE())->to_json_data;
is($notation,['COPY',['CASTDATE',$native->to_iso8601],['NODE']],'graft date literals serialize through CASTDATE');
$exec=JGraft::Exec->new(jgraft=>COPY('gone',NODE()),undo=>1);
$exec->apply($native);
my $undo=JSON::PP->new->decode(JSON::PP->new->encode($exec->undo->to_json_data));
is($undo->[-1][1][0],'CASTDATE','undo serializes removed date as CASTDATE');

SKIP: {
   skip 'Time::Piece is not installed',6 unless eval {require Time::Piece;1};
   my $tp=JGraft::Date->new('1970-01-01T00:00:00Z')->format('Time::Piece');
   isa_ok($tp,['Time::Piece'],'Time::Piece preset handles the epoch');
   is($tp->epoch,0,'epoch zero is a valid native object');
   my $converted=JGraft::Date->new(JGraft::Date->new('2024-01-02T03:04:05+0200')->to_time_piece);
   is($converted->_compare($native),0,'Time::Piece export preserves timestamp instant');
   is(jgexec(COPY(NODE('year'),NODE()),$tp),1970,'native Time::Piece virtual fields import');
   ok(!eval {JGraft::Date->new('2024-01-01T00:00:00.1Z')->to_time_piece;1},'Time::Piece rejects fractional loss');
   ok(!eval {JGraft::Date->new('2024-01-01T00:00:60Z')->to_time_piece;1},'Time::Piece rejects leap-second loss');
}
SKIP: {
   skip 'optional DateTime is not installed',8 unless eval {require DateTime;1};
   my $dt=JGraft::Date->new('2024-01-02T03:04:05.123456789+0200')->format('DateTime');
   isa_ok($dt,['DateTime'],'DateTime preset');
   is($dt->offset,7200,'DateTime preset preserves fixed offset');
   is($dt->nanosecond,123456789,'DateTime preset preserves nanoseconds');
   is(JGraft::Date->new($dt)->to_iso8601,'2024-01-02T03:04:05.123456789+0200','native DateTime import');
   is(jgexec(COPY(NODE('year'),NODE()),$dt),2024,'native DateTime virtual fields import');
   is($dt->year,2024,'input DateTime is not mutated');
   my $floating=JGraft::Date->new('2024-01-02 03:04:05')->to_datetime;
   is(JGraft::Date->new($floating)->type,'datetime','floating DateTime retains datetime kind');
   ok(!eval {$date->to_datetime;1},'DateTime rejects fractional precision loss');
}
my $callback_value=$native->format(sub {$_[0]->year});
is($callback_value,2024,'formatter callback receives the immutable date');
for my $limit ({new_obj=>0},{mem=>300},{ops=>5}) {
   $exec=JGraft::Exec->new(jgraft=>COPY(CASTSTR(CASTDATE('2024-01-01')),NODE()),limits=>$limit);
   $exec->apply(undef);
   is($exec->error,'RESOURCE_LIMIT','date evaluation respects resource limits');
}
$exec=JGraft::Exec->new(jgraft=>COPY(CASTSTR(CASTDATE()),NODE()));
$exec->apply('2024-01-01');
$exec->apply('2025-02-03');
is($exec->output,'2025-02-03','date state resets between applications');
my $iso='2024-01-02T03:04:05.125+0200';
is(jgexec(COPY(CASTDATE($iso),NODE()),undef),$iso,'default NODE export is ISO8601');
is(jgexec(JGRAFT(COPY(CASTDATE('2024-01-02'),'date'),
   COPY(IS(NODE('date'),CASTDATE('2024-01-02')),'typed'),
   COPY(NONE(IS(NODE('date','year'),EXISTS())),'noFields')),{}),
   {date=>'2024-01-02',typed=>JSON::PP::false,noFields=>JSON::PP::true},
   'later actions observe the exported NODE value');
my $calls=0;
my $format=sub { ++$calls; $_[0]->to_iso8601 };
my $graft=JGRAFT({const=>['date',CASTDATE($iso)]},
   COPY({a=>CONST('date'),b=>[CONST('date')]},NODE()),COPY(CONST('date'),'c'));
is(jgexec($graft,undef,date_format=>$format),{a=>$iso,b=>[$iso],c=>$iso},'callback formats nested dates');
is($calls,1,'one immutable date is formatted once across assignments and containers');
my $borrowed={dates=>[$native],unchanged=>{keep=>1}};
my $result=jgexec(COPY(NODE(),NODE()),$borrowed);
is($result->{dates},[$native->to_iso8601],'whole-container writes convert contained dates');
is(refaddr($borrowed->{dates}[0]),refaddr($native),'whole-container export preserves borrowed date');
is(refaddr($result->{unchanged}),refaddr($borrowed->{unchanged}),'export skips subtrees without dates');
isnt(refaddr($result->{dates}),refaddr($borrowed->{dates}),'export clones borrowed containers containing dates');
$exec=JGraft::Exec->new(jgraft=>JGRAFT(COPY(CASTDATE($iso),STASH('nested','date')),
   COPY(STASH('nested'),'out')));
$exec->apply({});
is($exec->output,{out=>{date=>$iso}},'deep namespace writes propagate date markers to ancestors');
is(jgexec(JGRAFT(COPY([CASTDATE($iso)],STASH('dates')),
   COPY(SLICE(STASH('dates'),0),NODE())),undef),[$iso],'sliced date arrays retain their export marker');
is(jgexec(ATSPLIT(NODE(),',',COPY(CASTDATE('2024-01-02'),1)),'a,b'),'a,2024-01-02',
   'NODE writes in ATSPLIT temporary roots also export dates');
for my $out (undef,0,JSON::PP::false) {
   is(jgexec(COPY(CASTDATE('2024-01-02'),NODE()),undef,date_format=>sub {$out}),$out,
      'formatter may return null, zero, or false');
}
my $sentinel=bless {},'DateFormatterError';
ok(!eval {jgexec(COPY(CASTDATE($iso),NODE()),undef,date_format=>sub {die $sentinel});1},'formatter exception propagates');
is($@,$sentinel,'formatter exception identity is preserved');
$calls=0;
$exec=JGraft::Exec->new(jgraft=>JGRAFT(COPY(CASTDATE($iso),STASH('date')),COPY(1,NODE())),date_format=>sub {++$calls;'unused'});
$exec->apply(undef);
is($calls,0,'namespace-only dates do not invoke the formatter');
$exec=JGraft::Exec->new(jgraft=>COPY(CASTDATE($iso),NODE()),date_format=>'Time::Piece',undo=>1);
$exec->apply('original');
is($exec->error,'UNSUPPORTED_GRAFT','preset rejects a lossy native conversion');
is($exec->output,'original','failed export preserves the destination');
is(jgexec($exec->undo,$exec->output),'original','undo works after export failure');
$exec=JGraft::Exec->new(jgraft=>COPY('changed',NODE()),undo=>1);
$exec->apply($native);
my $restored=jgexec($exec->undo->to_json_data,$exec->output);
is(JGraft::Date->new($restored)->to_iso8601,$native->to_iso8601,'serialized undo restores a date through the configured output format');
SKIP: {
   skip 'Time::Piece is not installed',2 unless eval {require Time::Piece;1};
   my $tp=jgexec(COPY(CASTDATE('1970-01-01T00:00:00Z'),NODE()),undef,date_format=>'Time::Piece');
   isa_ok($tp,['Time::Piece'],'execution Time::Piece preset');
   is($tp->epoch,0,'execution export preserves epoch zero');
}
SKIP: {
   skip 'optional DateTime is not installed',4 unless eval {require DateTime;1};
   my $dt=jgexec(COPY(CASTDATE($iso),NODE()),undef,date_format=>'DateTime');
   isa_ok($dt,['DateTime'],'execution DateTime preset');
   is($dt->nanosecond,125000000,'execution native export preserves fractions');
   my $source=DateTime->new(year=>2024,month=>1,day=>2,time_zone=>'UTC');
   my $copy=jgexec(JGRAFT(),{date=>$source},clone=>1);
   isnt(refaddr($copy->{date}),refaddr($source),'clone output detaches mutable DateTime objects');
   $copy->{date}->add(days=>1);
   is($source->day,2,'mutating cloned native output preserves input');
}
my ($status,$loading)=run_perl('-e','use JGraft qw(:constructors jgexec); jgexec(COPY(CASTDATE("2024-01-02"),NODE()),undef); print exists $INC{"DateTime.pm"} ? "loaded" : "optional";');
is($status,0,'ISO formatting works without loading DateTime');
is($loading,'optional','DateTime is loaded only when requested');
for my $bad (undef,'bad',[]) {
   ok(!eval {JGraft::Exec->new(date_format=>$bad);1},'invalid date formatter option is rejected');
}
done_testing;
