use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec jgparse);
use JGraft::Exec;
use JGraft::Expr::CHARS;
use JSON::PP ();
use Storable qw(nfreeze thaw);
use utf8 ();
use Encode ();
no warnings 'utf8';

my $json=JSON::PP->new->canonical->allow_nonref;
my $chars=CHARS(qr/[a-z0-3XYZ]/);
is($chars->invlist,[48,52,88,91,97,123],'regexp produces normalized inversion boundaries');
is($chars->to_json_data,['CHARS',48,51,97,122,'XYZ'],'four-character runs become ranges and short runs form the final string');
is(JGraft::Expr::CHARS->new(qr/[a-cf-ik]/)->to_json_data,['CHARS',102,105,'abck'],'direct regexp constructor separates three- and four-character runs');
is(JGraft::Expr::CHARS->new([qr/[b-dac-e]/])->invlist,[97,102],'overlapping ranges and duplicates coalesce');
is(CHARS(qr/[^a-z]/)->invlist,[0,97,123,0x110000],'complements stop at the Unicode boundary');
is(CHARS(qr/[\p{Any}]/)->to_json_data,['CHARS',0,0x10ffff],'full universe serializes without enumerating members');
is(CHARS(qr/[^\p{Any}]/)->to_json_data,['CHARS'],'empty universe serializes as an empty CHARS');
is(CHARS(qr/[\x00-\x02]/)->to_json_data,['CHARS',"\0\1\2"],'short control ranges become one string');
is(CHARS(qr/[\x{10FFFC}-\x{10FFFF}]/)->to_json_data,['CHARS',0x10fffc,0x10ffff],'maximum endpoint is numeric and inclusive');
isa_ok(dies {CHARS(qr/[a]+/)},['JGraft::Error'],'invalid regexp constructors use construction exceptions');
for my $bad (qr/a/,qr/./,qr/[a][b]/,qr/([a])/,qr/^[a]$/,qr/[a]|[b]/,qr/[a]{1}/,qr/[a]tail/) {
   like(dies {CHARS($bad)},qr/exactly one character class/,'reject regexp syntax outside one class');
}
like(dies {CHARS(qr/[a]/,'extra')},qr/INVALID_GRAFT/,'regexp form cannot have additional operands');
like(dies {JGraft::Expr::CHARS->new_from_json_data(['CHARS',qr/[a]/])},qr/INVALID_GRAFT/,
   'regexp refs are a native constructor form, not JSON notation');
my $fake=bless {},'Regexp';
like(dies {CHARS($fake)},qr/INVALID_GRAFT/,'a blessed object cannot impersonate a regexp');
my $inv=$chars->invlist;
ok(!eval {$inv->[0]=0;1},'inversion boundaries are immutable');
ok(!eval {push @$inv,0x110000;1},'inversion list length is immutable');
is($chars->entries,[48,51,97,122,'XYZ'],'regexp form exposes serializable entries');
my @patterns=(
   qr/[a-z0-9_]/,qr/[^a-z]/,qr/[]a-]/,qr/[a\-z]/,qr/[\[\]\\]/,
   qr/[\a\b\e\f\n\r\t]/,qr/[\x00\x41\x{100}\101\c?]/,
   qr/[[:digit:][:upper:]]/,qr/[[:^ascii:]]/,qr/[\d\s\w]/,
   qr/[\p{Lu}\P{ASCII}]/,qr/\d/,qr/\P{ASCII}/,
   qr/[a-z]/i,qr/[\x{DF}]/i,qr/[\x{FB05}]/i,qr/\pL/,
);
my @points=(0..127,128,160,233,256,0x17f,0x212a,0x345,0x3a3,0x3c3,0x660,0x200c,0xfb05,0xfb06,0x1f600,0xd800,0xffff,0x10ffff);
for my $re (@patterns) {
   my $expr=CHARS($re);
   my $list=$expr->invlist;
   my @expected;
   for my $cp (@points) {
      my $ch=chr($cp); utf8::upgrade($ch);
      push @expected,$ch =~ $re?1:0;
   }
   is([map JGraft::Expr::CHARS::_contains($list,$_),@points],\@expected,"class snapshot agrees with Perl: $re");
   my $roundtrip=JGraft::Expr::CHARS->new_from_json_data($expr->to_json_data);
   is($roundtrip->invlist,$list,'JSON notation preserves the complete membership set');
   for my $cp (65,97,233,0x1f600) {
      my $char=chr($cp); utf8::upgrade($char);
      my $expected=$char =~ $re?JSON::PP::true:JSON::PP::false;
      is(jgexec(COPY($expr,NODE()),$cp),$expected,'runtime uses regexp snapshot membership');
      is(jgexec(COPY($roundtrip,NODE()),$cp),$expected,'round-tripped runtime agrees');
   }
}
# These modes were added after Perl 5.8. Keep their syntax out of its parser.
for my $case (['qr/[\w\d]/a',5.014],['qr/ [ a-z ] /xx',5.026],
   [q{use charnames ':full'; qr/[\N{LATIN CAPITAL LETTER A}]/},0]) {
   SKIP: {
      skip "regexp syntax needs Perl $case->[1]",5 if $]<$case->[1];
      my $source=$case->[0];
      my $re=eval $source; die $@ unless defined $re;
      my $expr=CHARS($re);
      for my $cp (32,65,97,233,0x660) {
         my $ch=chr($cp); utf8::upgrade($ch);
         is(JGraft::Expr::CHARS::_contains($expr->invlist,$cp),$ch =~ $re?1:0,
            "regexp flags are respected: $source U+$cp");
      }
   }
}
is(CHARS(0,10,JSON::PP::false,3,6,JSON::PP::true,5)->invlist,[0,3,5,6,7,11],
   'ordered union and subtraction preserve later re-inclusion');
is(CHARS('aazzzbb')->invlist,[97,99,122,123],'ordinary strings normalize duplicate members');
is(CHARS(JSON::PP::false,0,0x10ffff)->invlist,[],'subtracting all codepoints yields an empty list');
is(CHARS(JSON::PP::false)->invlist,[0,0x110000],'initial false complements the empty set');
my $dynamic=CHARS(EXPR(TEMP('which')),JSON::PP::false,'b');
my $graft=JGRAFT({expr=>['a',CHARS(qr/[a-c]/),'b',CHARS(qr/[b-d]/)]},
   COPY([LOCAL('which','a',HAS(97,$dynamic)),LOCAL('which','b',HAS(97,$dynamic)),
      LOCAL('which','a',HAS(98,$dynamic)),LOCAL('which','b',HAS(100,$dynamic))],NODE()));
is(jgexec($graft,undef),[JSON::PP::true,JSON::PP::false,JSON::PP::false,JSON::PP::true],
   'dynamic aliases retain scope and ordered subtraction');
is($dynamic->to_json_data,['CHARS',['EXPR',['TEMP','which']],JSON::PP::false,'b'],
   'unresolved EXPR declarations retain their notation');
like(dies {$dynamic->invlist},qr/execution scope/,'unresolved declarations require a scope to build their list');
my $thawed=thaw(nfreeze($chars));
is($thawed->to_json_data,$chars->to_json_data,'Storable preserves regexp-derived classes');
ok(!eval {$thawed->invlist->[0]=0;1},'thawed inversion boundaries remain immutable');
ok(!eval {push @{$thawed->invlist},0x110000;1},'thawed inversion list length remains immutable');
is(jgparse(JGRAFT(COPY(STR($chars),NODE()))->to_json_data)->to_json_data,
   JGRAFT(COPY(STR($chars),NODE()))->to_json_data,'regexp classes survive nested graft serialization');
my $surrogate=CHARS(qr/[\x{D800}]/);
my $bytes;
{
   local $SIG{__WARN__}=sub {};
   $bytes=Encode::encode('UTF-32BE',chr(0xd800));
}
for my $expr ($surrogate,JGraft::Expr::CHARS->new_from_json_data($surrogate->to_json_data)) {
   is(jgexec(COPY($expr,NODE()),0xd800),JSON::PP::true,'preserve policy retains surrogate class membership');
   is(jgexec(COPY($expr,NODE()),vec($bytes,0,32),codepoint_policy=>'substitute'),JSON::PP::true,
      'regexp and serialized class use the same substitution policy');
}

my $members=join('',map chr(0x1000+2*$_),0..2047);
my $large=CHARS(qr/[$members]/);
my $exec=JGraft::Exec->new(jgraft=>COPY(STR(SEQ(START(),REP(200,0,$large),END())),NODE()),limits=>{ops=>60000});
$exec->apply(chr(0x1000)x200);
ok($exec->success,'large fragmented classes fit a logarithmic lookup budget') or diag "$exec";
is($exec->output,JSON::PP::true,'large class matches every repeated character');
$exec=JGraft::Exec->new(jgraft=>COPY($large,NODE()),limits=>{mem=>1000});
$exec->apply(0x1000);
is($exec->error,'RESOURCE_LIMIT','inversion-list execution respects memory limits');
done_testing;
