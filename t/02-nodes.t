use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgparse);
use JSON::PP ();
use Scalar::Util 'refaddr';

my $true= JSON::PP::true;
my $false= JSON::PP::false;
my $json= JSON::PP->new->canonical->allow_nonref;
my $node= NODE();
my $action= RAISE('info', 'message');
my %examples= (
   JGRAFT => [[{}], [{v=>1}, $action]],
   RAISE => [['info','message'], [2,'failure',undef]],
   AT => [['title'], [$node,$action]],
   ATSPLIT => [['content',' '], [$node,{sep=>CHARS(' '),default=>' '},$action]],
   MATCH => [[{title=>STR()}], [NUM(),$action]],
   IF => [[], [$action], [NUM(),$action], [NUM(),$action,$action]],
   COPY => [[42,'x'], [[1,2],NODE('x'),undef,'y']],
   MOVE => [['x','y'], [undef,'x','y',undef], [NODE(0),NODE(1.5)]],
   SPLICE => [[0,undef], [NODE(2),1,'replacement',[1,2]]],
   EXPR => [['example']], CAP=>[[],['name','ofs']], TEMP=>[[0]], STASH=>[[],['x']],
   CONST=>[[],['value']], NODE=>[[],['title'],[[0,1]]],
   HAS=>[[undef],[$node,{x=>NUM()}]], IS=>[[[1,2]],[$node,42]],
   NONE=>[[],[EXISTS()]], ANY=>[[1,2]], ALL=>[[NUM(),HAS(1)]],
   EXISTS=>[[]], ARRAY=>[[],[2],[0,NUM(),STR()]], STR=>[[],[CHARS('az')]],
   NUM=>[[],[0],[undef,3]], BOOL=>[[]], DATE=>[[]],
   WITH=>[['x',42,NUM()], ['x',42,'y',43,HAS(TEMP('x'))]],
   SEQ=>[[],[NUM(),STR()]], SEQMAX=>[[undef],['name',REP()]], SEQMIN=>[[1],['name',REP()]],
   REP=>[[],[1],[0,-1],[2,0,NUM()]], START=>[[]], END=>[[]],
   CHARS=>[[],[$false,'az',EXPR('other')]],
   CAPTURE=>[[ARRAY(0,SEQMAX('items',REP()))]],
   LOCAL=>[[$node],['x',42,TEMP('x')],[undef,[1,2],NODE()],[NODE('key'),1,TEMP('answer')]],
   NOT=>[[$true]], AND=>[[$true,$false]], OR=>[[$false,$true]],
   LENGTH=>[[],[[1,2]]], CURPROP=>[[]],
   SLICE=>[[{ofs=>1}],[[1,2,3],1],['abc',0,1]],
   CONCAT=>[['a','b'],[[1],[2]]],
   REDUCE=>[[ADD(TEMP('sum'),NODE()),'sum',0], [NODE(),'sum',undef,[1,2]]],
   FILTER=>[[NUM()],[NUM(),[1,2]]], MAP=>[[NODE()],[ADD(1,NODE()),[1,2]]],
   SPLIT=>[[' '],[{sep=>' ',trim=>CHARS(' ')},' a b ']],
   JOIN=>[[' '],[' ',['a','b']]], PROPS=>[[],[{}],[{},2]],
   MKOBJ=>[[],[[['x',1]]],['x',1],[['x'],[1]],['x',1,'incomplete']],
   CASE=>[[NUM(),1],[NUM(),1,STR(),2,FAIL()]], FAIL=>[[]],
   CASTBOOL=>[[],[1]], CASTNUM=>[[],['12']], CASTSTR=>[[],[12]], CASTDATE=>[[],['2026-01-01']],
   LESS=>[[2],[1,2]], LESSEQ=>[[2],[1,2]], ADD=>[[],[1,2],[[1,2]]],
   SUB=>[[3,1]], MUL=>[[],[2,3],[[2,3]]], DIV=>[[6,2]], MOD=>[[5,2]],
);

for my $registry ('JGraft::Action', 'JGraft::Expr') {
   no strict 'refs';
   my $names= \%{$registry.'::by_name'};
   for my $name (sort keys %$names) {
      my $class= $registry->get_class($name);
      ok(exists $examples{$name}, "$name has constructor examples");
      for my $args (@{$examples{$name}}) {
         my $obj= $class->new($args);
         isa_ok($obj, [$class, $registry]);
         is($obj->id, $names->{$name}, "$name ID");
         my $data= $obj->to_json_data;
         my $encoded= $json->encode($data);
         is($registry->new_from_json_data($data)->to_json_data, $data, "$name data round trip");
         my @numbered= ($names->{$name}, @$data[1..$#$data]);
         is($class->_parse(\@numbered)->to_json_data, $data, "$name numeric _parse");
         is($json->encode(\@numbered), $json->encode([$names->{$name}, @$data[1..$#$data]]), "$name numeric token retains its type");
         my %attrs= %$obj;
         delete $attrs{_form};
         is($class->new(%attrs)->to_json_data, $data, "$name named constructor");
         is($json->encode($data), $encoded, "$name input unchanged by parsing");
         is($obj->TO_JSON, $data, "$name TO_JSON");
         if ($registry eq 'JGraft::Expr') {
            is(!!$obj->is_ref, !!$class->isa('JGraft::Expr::Ref'), "$name reference flag");
            is(!!$obj->is_match, !!$class->isa('JGraft::Expr::Match'), "$name match flag");
            is(!!$obj->is_fn, !!$class->isa('JGraft::Expr::Fn'), "$name function flag");
         }
      }
   }
}

my $literal= ['ADD',1,2];
is(JGraft::Expr::ADD->returns, 4, 'numeric return declaration');
is(JGraft::Expr::CAPTURE->returns, 2|32, 'union return declaration');
is(JGraft::Expr::FAIL->returns, 0, 'non-returning declaration');
is(scalar @{JGraft::Expr::SLICE->forms}, 2, 'overloaded forms exposed directly');
is(JGraft::Expr::REP->forms->[0]{fields}[0], ['min','nonneg_int',0], 'form defaults preserved');
my $local_number= LOCAL('x',1,42);
is(JGraft::Expr::LOCAL->returns, 127, 'LOCAL class declaration remains general');
is($local_number->returns, 4, 'LOCAL instance refines its literal return type');
is(LOCAL('x',1,CASTSTR())->returns, 8, 'LOCAL instance refines expression return type');
is(LOCAL(LOCAL(CASTSTR()))->returns, 8, 'nested LOCAL return types refine recursively');
like(dies { REP(LOCAL(CASTSTR())) }, qr/cannot return/, 'validation uses refined LOCAL capabilities');
my $literal_expr= LENGTH($literal);
is($literal_expr->value_expr, $literal, 'constructor array stays literal');
is($literal_expr->to_json_data, ['LENGTH',[['ADD',1,2]]], 'literal array escaped on export');
my $parsed= JGraft::Expr->new_from_json_data(['LENGTH',[[1,['ADD',2,3],{nested=>[[]]}]]]);
isa_ok($parsed->value_expr->[1], ['JGraft::Expr::ADD']);
is($parsed->value_expr->[2]{nested}, [], 'nested empty array unescaped');
is(JGraft::Expr::REP->new(match_expr=>NUM())->to_json_data, ['REP',0,-1,['NUM']], 'named optional fields use positional defaults');
is(JGraft::Expr::NUM->new(max=>3)->to_json_data, ['NUM',undef,3], 'named upper bound inserts null lower bound');
is(jgparse('["JGRAFT",{},["COPY",[[1,2]],"x"]]')->actions->[0]->assignments->[0][0], [1,2], 'jgparse decodes nested actions and data');
my $graft= JGRAFT({const=>['list',[1,2]],expr=>['value',ADD(1,2)],custom=>['NODE']}, COPY(CONST('list'),'x'));
is(JGRAFT($action)->metadata, {v=>1}, 'JGRAFT convenience function supplies metadata');
is(JGRAFT()->actions, [], 'empty JGRAFT convenience call');
my $metadata= $graft->to_json_data->[1];
is($metadata->{const}, ['list',[[1,2]]], 'constant declaration values use value notation');
is($metadata->{expr}, ['value',['ADD',1,2]], 'common expressions use expression notation');
is($metadata->{custom}, ['NODE'], 'custom metadata remains literal JSON');
is($json->decode($json->convert_blessed->encode($graft)), $graft->to_json_data,
   'JSON encoder uses inherited TO_JSON methods');
is(jgparse($graft), $graft, 'jgparse passes through existing actions');
my $shared= [1,2];
ok(LENGTH([$shared,$shared]), 'shared input subtrees are allowed');
my $path_number= 1;
my $path_string= '1';
is(COPY(1,NODE($path_number))->to_json_data->[2], ['NODE',1], 'numeric selectors remain numeric');
is(COPY(1,NODE($path_string))->to_json_data->[2], ['NODE','1'], 'string selectors remain strings');
my $keys= {'__proto__'=>[1,2],constructor=>undef,''=>{},toString=>STR()};
is(JGraft::Expr->new_from_json_data(HAS($keys)->to_json_data)->to_json_data, HAS($keys)->to_json_data,
   'arbitrary object keys round trip');
is(JGraft::Expr->new_from_json_data(['AND',$false,['LENGTH',42]])->to_json_data,
   ['AND',$false,['LENGTH',42]], 'guarded INVALID_TARGET operands are preserved');
is(JGraft::Expr->new_from_json_data(['ANY',['FAIL'],1])->to_json_data,
   ['ANY',['FAIL'],1], 'intentional failure remains a match alternative');
is(JGraft::Expr->new_from_json_data(['ANY',['MKOBJ'],['IS',undef]])->to_json_data,
   ['ANY',['MKOBJ'],['IS',undef]], 'MKOBJ shape failure stays a runtime failure');
is(JGraft::Expr->new_from_json_data(['CASE',1,['LOCAL',$false,1,['NODE']],2])->to_json_data,
   ['CASE',1,['LOCAL',$false,1,['NODE']],2], 'LOCAL name failure can be guarded by CASE');
for my $ignored (undef, $false, 42, {}, [1,2], NUM()) {
   ok(SPLIT({sep=>CHARS('az'),default=>$ignored}), 'SPLIT does not validate an unused default');
   ok(JOIN({sep=>',',default=>$ignored}), 'constant separator ignores default');
   ok(JOIN({sep=>CHARS('az'),keep=>'@',default=>$ignored}), 'kept separator ignores default');
}

for my $case (
   [sub { JGraft::Expr::SUB->new([1]) }, qr/INVALID_GRAFT/],
   [sub { JGraft::Action::COPY->new([1]) }, qr/INVALID_GRAFT/],
   [sub { JGraft::Expr::NUM->new_from_json_data(['STR']) }, qr/does not inherit/],
   [sub { JGraft::Expr->new_from_json_data([]) }, qr/at least one element/],
   [sub { JGraft::Expr->new_from_json_data(['LENGTH',[]]) }, qr/escaped/],
   [sub { JGraft::Expr->new_from_json_data(['UNKNOWN']) }, qr/Unknown/],
   [sub { JGraft::Expr->new_from_json_data([{}]) }, qr/name or ID/],
   [sub { NODE(undef) }, qr/path selector/],
   [sub { NODE($true) }, qr/path selector/],
   [sub { TEMP() }, qr/INVALID_GRAFT/],
   [sub { REDUCE(NODE(),undef,0) }, qr/property name/],
   [sub { AT(STASH('x')) }, qr/must use NODE/],
   [sub { COPY(1,CONST('x')) }, qr/Read-only/],
   [sub { COPY(1,NODE(1.5)) }, qr/path selector/],
   [sub { COPY(1,STASH()) }, qr/namespace root/],
   [sub { REP(CASTSTR(1)) }, qr/cannot return/],
   [sub { REP(-1) }, qr/non-negative/],
   [sub { REP(3,2) }, qr/reversed/],
   [sub { NUM(3,2) }, qr/reversed/],
   [sub { RAISE('debug','message') }, qr/level/],
   [sub { RAISE('info',42) }, qr/message/],
   [sub { RAISE('info',"bad\nmessage") }, qr/forbidden/],
   [sub { CHARS(NODE()) }, qr/only permits EXPR/],
   [sub { CHARS('z','a') }, qr/reversed/],
   [sub { SPLIT({sep=>' ',unknown=>1}) }, qr/Unknown split/],
   [sub { SPLIT({sep=>' ',discard=>1}) }, qr/boolean/],
   [sub { SPLIT({sep=>' ',trim=>' ',ltrim=>' '}) }, qr/combined/],
   [sub { JOIN({sep=>CHARS('az')}) }, qr/default separator/],
   [sub { JGRAFT({const=>['x']}) }, qr/name\/value pairs/],
   [sub { JGraft::Expr::NODE->new(unknown=>1) }, qr/attributes/],
   [sub { JGraft::Expr::NUM->new(min=>1,min=>2) }, qr/Duplicate/],
   [sub { LENGTH(bless({},'NotJSON')) }, qr/Expected JSON/],
) {
   my $ok= eval { $case->[0]->(); 1 };
   ok(!$ok, 'invalid constructor or notation rejected');
   like($@, $case->[1], 'useful diagnostic');
}
my $cycle= [];
push @$cycle, $cycle;
like(dies { LENGTH($cycle) }, qr/Cyclic/, 'constructor rejects cycles');
my $cyclic_notation= ['LENGTH'];
push @$cyclic_notation, $cyclic_notation;
like(dies { JGraft::Expr->new_from_json_data($cyclic_notation) }, qr/Cyclic/, 'parser rejects expression cycles');
done_testing;
