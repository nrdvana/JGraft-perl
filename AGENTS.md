# JGraft Perl 5 Implementation

This implementation should be complete, performant, and widely compatible.  The code should
be optimized for recent perl interpreters (a moving target of the last-5-years or so).
Support back to 5.8 is also required, but alternative code can be added without degrading the
quality of the modern implementation using source markers like `#__p5.28__` / `#__p<5.28__` /
`#__pEND__` which denotes blocks to comment/uncomment on older perl versions.
See `perldoc inc/ExtUtils/PerlVersionFilter.pm` for details.
Use a minimalist style without frameworks.  Avoid non-core dependencies where reasonable,
allowing modules that became core in later Perls.  Test2 is the test framework; DateTime remains
optional.

Aim for algorithms and data structures that can apply the most JGrafts possible within modest
resource limits.  Balance execution speed against memory usage and code complexity; i.e. don't
use massive caches that exhause the memory budget just to lower the runtime complexity of a few
edge cases, but otherwise do use the best algorithm known for solving the problem.   Public
interfaces to complex state should generally be object-oriented, with exported helper functions
where reasonable; internals should use plain hashes, arrays, and functions if they improve
performance vs. an object abstraction.

The implementation should support operating on objects that behave like scalars (Math::BigNum,
etc), tied hashes and arrays, and eventually even an object-oriented interface for objects which
are meant to be mutated by JGraft.  Working with mutable objects *may* be restricted to when
graft execution is configured not to preserve the input.  An eventual goal is to be able to
mutate DBIx::Class row objects through their public API using JGraft.

## Sources and current scope

- `jgraft-spec/SpecV1.md` defines the language. Public POD and tests define the Perl-specific
  contracts. Do not change conformance fixtures merely to make an implementation change pass.
  If a conformance test looks wrong, ask.
- `IMPLEMENTATION.md` describes current internals, build details, and test coverage.
  Consult the relevant sections rather than relying on historical session logs.

Execution supports all required portions of the spec. Exact JSON round-trip (via JGraft::JSON)
and pretty-printing of JGraft directives are also implemented. Diffing (`JGraft::Diff`) remains
unimplemented.

## Public API

`JGraft.pm` contains functions and constants that consumers might want; it is not an object.
The API is defined in that file.  Do not alter that API without user approval.  It can be
conveniently consumed with `perldoc src/JGraft.pm`, but as a summary:
  - `jgparse` parses a graft from JSON source text
  - `jgexec` executes a graft on an input
  - `jgformat` flattens a graft back to JSON text
  - `json_data` is a utility to load json from various sources
  - `:constructors` exports one uppercase constructor function for each JGraft directive

`JGraft/Date.pm` holds immutable normalized dates, including fractional precision, and
imports/exports Time::Piece and optional DateTime values.

`JGraft/JSON.pm` and its hierarchy preserve exact number tokens, string spelling, object
member order, and untouched duplicate members.  It can also preserve whitespace and comments
if enabled.  It can also perform filtering and formatting during encode.

`Action.pm` and `Expr.pm` declare node classes; `_Node.pm` shares construction,
validation, and serialization. Most per-node files are loading/POD shims.
`Expr/CHARS.pm` contains its implementation. Preserve independent class loading
and Storable round trips without forcing parsing-only users to load Exec.

`Exec.pm` owns application state and action/value-expression execution.
`_Match.pm` and `_Sequence.pm` implement matching; `_Split.pm` and `_String.pm`
handle formatting metadata and packed character views; `_Undo.pm` builds reverse
grafts lazily. `Util.pm` provides shared public type and numeric helpers.

For directive classes, `Class->new([...])` receives operands only, with arrays interpreted as
literals and nested actions/expressions already parsed. Named attributes are also supported.
`new_from_json_data([...])` receives a **decoded** notation array including its operation
name/ID, recursively parses expressions, and unescapes literal arrays.  `jgparse` handles JSON
text and the supported input adapters.

Constructor validation checks grammar, intrinsic literal restrictions, and possible
return types. Leave target-dependent and guarded failures for runtime. Preserve
construction errors' context without retaining operand trees.

Completed action and expression nodes, including their entire operand trees, are
immutable by contract. Accessor-returned references and operands reachable through
other aliases must be treated as read-only. Recursive readonly enforcement is not
required; modifying exposed nodes or operands is unsupported. To change a graft,
construct new nodes and reuse unchanged ones. Internal builders, including undo
generation, may mutate nodes before exposing them; cache only completed nodes.

Optimizations may cache syntax-derived facts across executions. Private caches may
change internally without changing node semantics, but must preserve serialization,
Storable round trips, and node lifetimes. Execution-specific state stays outside
nodes: input-dependent results, resolved paths, namespace bindings, and callback
decisions cannot be reused merely because the syntax is immutable. This contract
does not make application input/output data immutable between executions.

## Build and Perl compatibility

Build with the interpreter being tested before running tests against `blib`:

```sh
perl Makefile.PL
make
prove -bv t/04-exec.t
```

Use `make test` for the full suite. For compatibility checks, repeat with
`perl5.28` / `prove5.28` and `perl5.8` / `prove5.8` where available. Rerun
`Makefile.PL` when switching interpreters in one checkout; use separate build
directories for concurrent interpreter tests. `prove -l` or directly loading
`lib/` bypasses required preprocessing.

Edit source under `lib/`, not generated `blib/lib`. Version-specific code uses:

```perl
#__p5.28__
modern_code();
#__p<5.28__
#legacy_code();
#__pEND__

#__pSUFFIX__
   modern_line();     #__p5.28__
#   legacy_line();     #__p<5.28__
```

Conditions are `pX` (X or newer), `p<Y` (older than Y), or `pX<Y`. Block markers
start in column one, appear in strictly decreasing non-overlapping order, may end
with a `#__pELSE__` catch-all branch, and cannot nest. Only a first branch with no
upper bound is live in the source: every nonblank line of any other branch starts
with `#`; use `##` for a comment there. If live code is disabled and no other
branch applies, the build dies; add an empty `#__pELSE__` branch when that is
intended. A marker ending a code line applies to that line only and never dies;
this form is recognized only after a `#__pSUFFIX__` line in the same file, and
never in POD.
`inc/ExtUtils/PerlVersionFilter.pm` documents the full syntax and preserves source
line numbers while producing the selected version in `blib/lib`.

`Makefile.PL` and `META.json` are generated checkout copies. Change packaging
configuration in `dist.ini`, then regenerate those copies from `dzil build`.
New source files must be Git-known for `[Git::GatherDir]` to include them in a
distribution. See IMPLEMENTATION.md for toolchain and optional adapter setup.

## Resource accounting

The public counters are `ops`, `mem`, `new_obj`, and `depth`; `undef` disables an
individual limit and zero is an active limit. The following `mem` contract is a
planned change for the refactor; the current implementation also charges scratch
space cumulatively.

- `ops`: estimated work, including every iterative algorithm and long native
  string/number operations. Reserve known work before loops; charge dynamic
  exploration incrementally. Short-circuit behavior must remain intact.
- `mem`: cumulative estimated retained allocations, including constructed values,
  ownership/undo metadata, namespaces, and caches. Never subtract when such data
  may have been freed. Exclude call-scoped scratch from this cumulative counter;
  this is a lifetime convention, not Perl's physical heap/stack distinction.
- `new_obj`: allocation count, including the value/representation allocations
  already charged by execution. It is not the current size of an ownership table.
- `depth`: maximum logical nesting, including structural traversal and macro
  expansion even when implemented iteratively. Removing wrapper calls must not
  remove semantic depth checks.

Scratch whose upper bound is estimated to be below ~1KB may be omitted from
accounting entirely if the function returns before calling into other functions
which track resources. Otherwise, the computed scratch must fit within the memory
limit while live.  Add the scratch size to a private `scratch_mem` field with Perl
`local` at the owning call boundary; memory checks use cumulative `mem` plus active
`scratch_mem`, including nested calls and any retained allocation made while scratch
is live. Restore the scratch reservation on return or exception; do not subtract
from cumulative `mem`.  Count the full estimated workspace, not just the
excess above 1 KiB; combine simultaneous scratch allocations within that call.

Reserve before allocating/growing large scratch buffers. Helpers may share a
caller's reservation, but returned workspace must remain covered until its owner
finishes. Constructed values that can escape, including expression results, are
retained allocations even if a caller later discards them. Do not classify all
of `apply` as scratch or introduce general tree lifecycle tracking. See section 6
of EXEC-INTERNALS-DESIGN.md for classification and the scoped-counter pattern.

Keep expensive work charged to `ops` even when its storage is scratch. Assign each
cost one owner to avoid duplicate charges. Public counters do not roll back with
failed probes; the private scratch reservation unwinds with its scope. Estimates
may change when work is removed; avoid hard-coding old totals into new tests.

## Testing

Use Test2 through `t/lib/Test2AndUtils.pm`; put shared imports, boilerplate, and
helpers there. Extend the nearest existing test for a behavioral change.

Run focused tests during each step, then the full suite for execution changes.
Before completing a refactor affecting shared runtime or preprocessing code, check
modern Perl, the 5.28 boundary, and 5.8.9; report any unavailable interpreter.
Useful test groups:

- `00`–`03`: generated syntax, source filtering, nodes, and loading.
- `04`, `06`–`08`: execution/COW, lazy undo, errors, and namespaces.
- `10`, `12`, `14`, `16`: matching, sequences, strings, and split metadata.
- `18`–`23`: dates, CHARS, collections, SPLICE/RAISE, transport, and exact JSON.
- `05` and `24`: full conformance with native and exact-JSON transport, including
  serialized undo round trips. These need the specification checkout; do not
  report a skipped conformance run as coverage of the fixtures.

For mutation/accounting changes, test partial resource failures, input preservation,
finalized MOVE arrays, undo of partial output, alias isolation, and context reuse.
Use the shared conformance runner's typed comparisons; generic string comparisons
can conceal JSON number/string/boolean regressions. Update IMPLEMENTATION.md when
implemented behavior or build instructions change, keeping proposals distinct.
