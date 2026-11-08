use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgexec);
use JGraft::Exec;
use JGraft::_Split;
use Scalar::Util qw(refaddr weaken);

my $spec={sep=>ANY(':','|'),default=>'/',trim=>REP(0,-1,CHARS(' '))};
my $text=' a :  b |   c ';
sub split_case {
   my ($name,$input,$graft,$expected)=@_;
   test_conformance({name=>$name,input=>$input,jgraft=>$graft->to_json_data,output=>$expected});
}
split_case('overwrite retains destination metadata',$text,
   ATSPLIT(NODE(),$spec,COPY('X',1)),' a :  X |   c ');
split_case('move carries original separator and both trimmings',$text,
   ATSPLIT(NODE(),$spec,MOVE(NODE(2),NODE(-.5))),'   c | a :  b ');
split_case('new inserted element inherits only preceding indent',$text,
   ATSPLIT(NODE(),$spec,MOVE(undef,NODE(.5)),COPY('new',1)),' a : new:  b |   c ');
split_case('delete shifts metadata with surviving values',$text,
   ATSPLIT(NODE(),$spec,MOVE(NODE(0),undef)),'  b |   c ');
split_case('replacing all metadata rows leaves no adjacency to inherit',$text,
   ATSPLIT(NODE(),$spec,MOVE(NODE(0),undef,NODE(1),undef,NODE(2),undef,
      undef,NODE(-.5),undef,NODE(-.5)),COPY('x',0,'y',1)),'x/y');
split_case('array construction carries direct-reference metadata',$text,
   ATSPLIT(NODE(),$spec,COPY([NODE(2),NODE(0)],NODE())),'   c | a ');
split_case('function-derived values do not carry element metadata',$text,
   ATSPLIT(NODE(),$spec,COPY([SLICE(NODE(2),0),NODE(0)],NODE())),'c: a ');
split_case('final row inherits the actual preceding separator',$text,
   ATSPLIT(NODE(),$spec,COPY([NODE(-1),'end'],NODE())),'   c |   end');
split_case('plain prefix acquires following separator when array is upgraded',$text,
   ATSPLIT(NODE(),$spec,COPY(['plain',NODE(0)],NODE())),'plain: a ');
split_case('slice retains origin for subsequent reordering',$text,
   ATSPLIT(NODE(),$spec,COPY(SLICE(NODE(),1),NODE()),MOVE(NODE(1),NODE(-.5))),'   c |  b ');
split_case('different origins use destination adjacency',undef,
   JGRAFT(COPY(SPLIT($spec,' a :  b '),STASH('a'),SPLIT($spec,'   x |    y '),STASH('b')),
      MOVE(STASH('a',0),STASH('b',2)),COPY(JOIN($spec,STASH('b')),NODE())),'   x |    y |    a');
split_case('same-origin slices transfer metadata between arrays',$text,
   ATSPLIT(NODE(),$spec,COPY(SLICE(NODE(),0,1),STASH('first'),SLICE(NODE(),1),NODE()),
      MOVE(STASH('first',0),NODE(2))),'  b |   c | a ');
split_case('object property transfer loses element metadata',$text,
   ATSPLIT(NODE(),$spec,COPY(NODE(0),STASH('value')),COPY([STASH('value'),'end'],NODE())),'a/end');
split_case('overwriting a sibling copy does not edit source metadata',$text,
   JGRAFT(COPY(SPLIT($spec),STASH('a'),STASH('a'),STASH('b')),
      MOVE(STASH('b',2),STASH('b',-.5)),
      COPY([JOIN($spec,STASH('a')),JOIN($spec,STASH('b'))],NODE())),[$text,'   c | a :  b ']);
split_case('nested ATSPLIT restores both current-node scopes',{text=>'a b:c d'},
   JGRAFT(ATSPLIT('text',':',ATSPLIT(1,' ',COPY('D',1))),COPY(1,'finished')),
   {text=>'a b:c D',finished=>1});
split_case('JOIN leaves unused trimming expressions unevaluated',['a','b'],
   COPY(JOIN({sep=>',',trim=>FAIL(),element=>FAIL()}),NODE()),'a,b');
split_case('metadata is preserved in cloned values',$text,
   JGRAFT(COPY(SPLIT($spec),STASH('a')),
      COPY([STASH('a'),STASH('a')],NODE()),AT(NODE(0),MOVE(NODE(2),NODE(-.5))),
      COPY([JOIN($spec,NODE(0)),JOIN($spec,NODE(1))],NODE())),['   c | a :  b ',$text]);

my $original=JGraft::Expr::SLICE->can('_execute');
my $calls=0;
{
   no warnings 'redefine';
   local *JGraft::Expr::SLICE::_execute=sub {++$calls; goto &$original};
   is(jgexec(ATSPLIT(NODE(),{sep=>ANY(':','|'),default=>SLICE(NODE(),3,1),trim=>SLICE(NODE(),0,1)},
      COPY(['x','y'],NODE())),' a : b '),'x:y','ATSPLIT uses pre-evaluated join default after replacing its array');
}
is($calls,2,'default and trim value expressions each execute once');
my $input={text=>$text,untouched=>['shared']};
my $graft=JGRAFT(COPY(1,'before'),ATSPLIT('text',$spec,COPY('changed',0),MATCH(['impossible'])));
my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1);
$exec->apply($input);
is($exec->error,'NO_MATCH','subaction failure propagates');
is($exec->output,{%$input,before=>1},'failed ATSPLIT does not publish its temporary array');
is(jgexec($exec->undo,$exec->output),$input,'undo restores preceding writes after failed ATSPLIT');
is(refaddr($exec->output->{untouched}),refaddr($input->{untouched}),'ATSPLIT leaves unrelated subtrees shared');
$exec=JGraft::Exec->new(jgraft=>ATSPLIT('text',$spec,COPY(5,0)),undo=>1);
$exec->apply($input);
is($exec->error,'INVALID_TARGET','JOIN rejects nonstring edited elements');
is($exec->output,$input,'join failure preserves original string');
is(jgexec($exec->undo,$exec->output),$input,'undo works after reassembly failure');

# Bound conversion, token allocation, and successor exploration separately.
for my $limits ({new_obj=>10},{mem=>4000},{ops=>200}) {
   $exec=JGraft::Exec->new(jgraft=>JGRAFT(COPY(1,'before'),ATSPLIT('text','',COPY('x',0))),undo=>1,limits=>$limits);
   my $data={text=>'a'x1000};
   $exec->apply($data);
   is($exec->error,'RESOURCE_LIMIT','tokenization respects its resource budget');
   is($exec->output->{text},$data->{text},'resource failure leaves the source string intact');
   is(jgexec($exec->undo,$exec->output),$data,'undo restores preceding changes after split resource failure');
}
# Scalars and metadata must survive packed conversion without JSON transport.
for my $cp (0x1f600,0xd800,0xffff,0x10ffff) {
   no warnings 'utf8';
   my $s='a'.chr($cp).'b';
   is(jgexec(ATSPLIT(NODE(),{sep=>SEQ($cp),default=>'/'},COPY('B',1)),$s),'a'.chr($cp).'B',
      sprintf('SPLIT metadata preserves U+%X separator',$cp));
}
my $reuse=JGraft::Exec->new(jgraft=>COPY(JOIN($spec,SPLIT($spec)),NODE()));
$reuse->apply($text);
is($reuse->output,$text,'round trip creates metadata');
$reuse->apply('x:y');
is($reuse->output,'x:y','new execution resets metadata origins');
{
   my @mem;
   for my $count (1,10) {
      my $exec=JGraft::Exec->new(jgraft=>COPY(map {(JOIN(',',NODE('parts')),'result')} 1..$count));
      $exec->apply({parts=>['a','b']});
      ok($exec->success,'repeated JOIN configuration resolves successfully');
      is($exec->output->{result},'a,b','JOIN configuration preserves the separator');
      is($exec->{scratch_mem},0,'consuming JOIN call releases configuration workspace');
      push @mem,$exec->counters->{mem};
   }
   cmp_ok($mem[1]-$mem[0],'>=',9*length('a,b'),'each constructed JOIN string remains retained');
   cmp_ok($mem[1]-$mem[0],'<=',9*8*length('a,b'),'completed private configurations do not accumulate retained mem');
}
{
   my (@mem,@objects);
   for my $count (1,25) {
      my $graft=ATSPLIT(NODE(),$spec,COPY(map {(NODE(0),STASH('sink'))} 1..$count));
      my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1);
      $exec->apply($text);
      ok($exec->success,'repeated direct references preserve split provenance');
      is($exec->output,$text,'private element transfers preserve the original formatting');
      is($exec->{scratch_mem},0,'provenance reservation unwinds after its consuming COPY');
      push @mem,$exec->counters->{mem};
      push @objects,$exec->counters->{new_obj};
      my $count=$exec->counters;
      is(jgexec($exec->undo,$exec->output),$text,'undo of private provenance transfers restores input');
      is($exec->counters,$count,'lazy undo does not consume the execution budget');
   }
   is($mem[1],$mem[0],'discarded provenance records do not accumulate retained memory');
   is($objects[1],$objects[0],'provenance lifetime does not alter value allocation counts');
}
{
   my $input={text=>$text,items=>['left','right']};
   my $graft=JGRAFT(COPY(1,'before',SPLIT($spec,NODE('text')),STASH('parts')),
      MOVE(NODE('items',0),undef,STASH('parts',2),NODE('items',2)));
   my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1);
   my $put=JGraft::Exec->can('_set_member');
   my $seen=0;
   {
      no warnings 'redefine';
      local *JGraft::Exec::_set_member=sub {
         my ($self,$array,$key,$value,$source)=@_;
         if (refaddr($self)==refaddr($exec) && $source && ref($array) eq 'ARRAY' && $value eq 'c') {
            ++$seen;
            cmp_ok($self->{scratch_mem},'>',0,'destination allocation sees live source workspace');
            $self->{limits}{mem}=$self->counters->{mem}+$self->{scratch_mem};
         }
         return $put->(@_);
      };
      $exec->apply($input);
   }
   is($seen,1,'resource failure occurs while consuming direct-reference provenance');
   is($exec->error,'RESOURCE_LIMIT','retained growth checks memory including live provenance');
   is($exec->output,{text=>$text,items=>['right'],before=>1},'MOVE finalizes earlier deletion after provenance failure');
   is($input,{text=>$text,items=>['left','right']},'failed provenance transfer leaves caller input unchanged');
   is($exec->{scratch_mem},0,'MOVE failure releases source and path workspace');
   my $count=$exec->counters;
   my $undo=$exec->undo;
   is($exec->counters,$count,'partial undo leaves failed execution counters unchanged');
   is(jgexec($undo->to_json_data,$exec->output),$input,'serialized undo restores the finalized partial MOVE');
   $exec->{limits}{mem}=undef;
   $exec->apply($input);
   ok($exec->success,'context reuse clears the provenance failure');
   is($exec->output->{items},['right','c'],'reuse performs the requested element transfer');
   is($exec->{scratch_mem},0,'successful reuse releases provenance workspace');
}
{
   my $many=join(':',(' x ')x100);
   my @prepare=(COPY(1,'before',SPLIT($spec,NODE('text')),STASH('parts')),
      COPY(STASH('parts'),STASH('saved')));
   for my $case (
      ['_copy_meta',MAP(NODE(),STASH('parts'))],
      ['_copy_meta',FILTER(STR(),STASH('parts'))],
      ['_append_meta',CONCAT(STASH('parts'),STASH('parts'))],
   ) {
      my ($method,$expr)=@$case;
      my $graft=JGRAFT(@prepare,COPY($expr,STASH('result')));
      my $input={text=>$many};
      my $exec=JGraft::Exec->new(jgraft=>$graft,undo=>1);
      my $required;
      our $active;
      my $helper=JGraft::_Split->can($method);
      my $scratch=JGraft::Exec->can('_scratch_set');
      {
         no warnings 'redefine';
         no strict 'refs';
         local *{"JGraft::_Split::$method"}=sub {
            local $active=1;
            return $helper->(@_);
         };
         local *JGraft::Exec::_scratch_set=sub {
            my ($self,$base,$bytes)=@_;
            $required=$self->counters->{mem}+$base+$bytes if $active && !defined($required);
            return $scratch->(@_);
         };
         $exec->apply($input);
      }
      ok($exec->success,"$method baseline succeeds");
      ok(defined($required),"$method reserves its copy workspace");
      my $limited=JGraft::Exec->new(jgraft=>$graft,undo=>1,limits=>{mem=>$required-1});
      $limited->apply($input);
      is($limited->error,'RESOURCE_LIMIT',"$method rejects insufficient copy workspace");
      like($limited->message,qr/scratch/,"$method fails while reserving temporary storage");
      is($limited->output,{text=>$many,before=>1},"$method failure preserves prior edits");
      is($limited->{scratch_mem},0,"$method failure unwinds workspace");
      is(jgexec($limited->undo->to_json_data,$limited->output),$input,"$method partial undo restores input");
      is($input,{text=>$many},"$method failure preserves caller input");
      $limited->{limits}{mem}=undef;
      $limited->apply($input);
      ok($limited->success,"$method context can be reused after failure");
   }
}
{
   my $meta=JGraft::Exec->can('_split_meta');
   my (@owners,@metadata);
   my $called=0;
   my $exec=JGraft::Exec->new(jgraft=>JGRAFT(
      COPY(SPLIT($spec,' a :  b '),STASH('parts')),COPY(undef,STASH('parts')),
      COPY(CASTDATE('2024-01-02'),'date')),date_format=>sub {
         ++$called;
         ok(@owners && !grep(defined($_),@owners),'discarded split owners die before application cleanup');
         return 'formatted';
      });
   {
      no warnings 'redefine';
      local *JGraft::Exec::_split_meta=sub {
         if (@_>2 && defined($_[2])) {
            push @owners,$_[1];
            weaken($owners[-1]);
            push @metadata,$_[2];
         }
         return $meta->(@_);
      };
      $exec->apply({});
   }
   ok($exec->success,'metadata owner lifetime does not affect later execution');
   is($called,1,'later formatter observes the discarded split owner');
   ok(!grep(exists($_->{array}),@metadata),'split metadata has no owner back-reference');
   is($exec->output,{date=>'formatted'},'discarding split metadata leaves public output unchanged');
}
done_testing;
