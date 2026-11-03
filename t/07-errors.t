use strict;
use warnings;
use lib 't/lib';
use Test2AndUtils;
use JGraft qw(:constructors jgparse);
use JGraft::Util 'invalid_graft';
use JGraft::Exec;
use Scalar::Util qw(weaken refaddr);

my $error=dies { NUM(3,2) };
isa_ok($error,['JGraft::Error']);
is($error->code,'INVALID_GRAFT','validation uses a structured error code');
is($error->message,'NUM bounds are reversed','message is separate from diagnostics');
is($error->context,[{class=>'JGraft::Expr::NUM',method=>'new'}],'constructor context captured');
ok($error,'exception is true');
like("$error",qr/^INVALID_GRAFT: NUM bounds are reversed/,'string form retains error prefix');
like("$error",qr/constructing JGraft::Expr::NUM->new/,'string form identifies construction');
ok(!ref($error->stack_trace),'stack trace is text');
like($error->stack_trace,qr/JGraft::Expr::NUM::_validate/,'Carp records the validator');
like($error->stack_trace,qr/07-errors\.t line \d+/,'Carp records the caller location');

$error=dies { JGraft::Expr::NUM->new(min=>1,min=>2) };
is($error->context->[0]{class},'JGraft::Expr::NUM','named constructor errors have context before argument binding');
like($error->message,qr/Duplicate/,'named argument failure preserved');

$error=dies { JGraft::Expr::SUB->new([1]) };
is($error->code,'INVALID_GRAFT','arity failure uses exception');
is($error->context->[0]{class},'JGraft::Expr::SUB','arity context');

$error=dies { JGraft::Expr::REP->new([CASTSTR(1)]) };
is($error->context->[-1]{operand},'min','fixed operand name recorded');
is($error->context->[-1]{index},0,'fixed operand index recorded');

$error=dies { jgparse(['JGRAFT',{},['COPY',['ADD',['NUM',3,2]],'x']]) };
isa_ok($error,['JGraft::Error']);
is([map $_->{class}, @{$error->context}],
   ['JGraft::Action','JGraft::Action::JGRAFT','JGraft::Action::COPY','JGraft::Expr::ADD','JGraft::Expr::NUM'],
   'nested parsing captures enclosing construction frames');
is($error->context->[1]{operand},'actions','enclosing action operand recorded');
is($error->context->[2]{operand},'assignments','enclosing COPY operand recorded');
is($error->context->[2]{index},0,'COPY value index recorded');
my $saved=[map +{%$_}, @{$error->context}];
NUM(0,1);
is($error->context,$saved,'context survives unwinding and later successful construction');

for my $case (
   sub { JGraft::Expr->new_from_json_data([]) },
   sub { JGraft::Expr->new_from_json_data(['UNKNOWN']) },
   sub { JGraft::Action->new_from_json_data(['UNKNOWN']) },
   sub { JGraft::Expr::NUM->new_from_json_data(['STR']) },
   sub { ATSPLIT(NODE(),CHARS('az')) },
) {
   $error=dies { $case->() };
   isa_ok($error,['JGraft::Error']);
   is($error->code,'INVALID_GRAFT','parser/override failure uses exception');
   ok(@{$error->context}>0,'parser/override failure has construction context');
}
is($error->context->[-1]{class},'JGraft::Action::ATSPLIT','delegation to JOIN retains ATSPLIT context');

sub throw_from_util { invalid_graft('bad ', 'input') }
$error=dies { throw_from_util() };
is($error->message,'bad input','throw helper concatenates message parts');
is($error->context,[],'construction context does not leak into independent throws');
like($error->stack_trace,qr/main::throw_from_util/,'utility throw captures Carp stack');
my $trace=$error->stack_trace;
my $rethrown=dies { die $error };
is(refaddr($rethrown),refaddr($error),'rethrow retains exception identity');
is($rethrown->stack_trace,$trace,'rethrow preserves original text trace');
$error=dies { invalid_graft('0') };
ok($error,'false-looking message does not hide failure');

my $weak;
{
   my $input=bless {},'NotJGraftData';
   $weak=$input;
   weaken($weak);
   $error=dies { LENGTH($input) };
}
is($weak,undef,'error context and Carp text do not retain input objects');
for my $frame (@{$error->context}) {
   ok(!grep(ref($_),values %$frame),'construction context contains only descriptive scalars');
}

my $exec=JGraft::Exec->new(jgraft=>['JGRAFT',{},['COPY',['NUM',3,2],'x']]);
$exec->apply({});
is($exec->error,'INVALID_GRAFT','execution API retains its error code');
isa_ok($exec->diagnostic->{cause},['JGraft::Error']);
is($exec->diagnostic->{cause}->context->[-1]{class},'JGraft::Expr::NUM','execution preserves the structured parse failure');
$exec=JGraft::Exec->new(jgraft=>JGRAFT());
$exec->apply({});
is($exec->error,undef,'construction context does not affect later execution');
done_testing;
