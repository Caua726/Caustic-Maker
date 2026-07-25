# caustic-mk

![version](https://img.shields.io/badge/version-0.2.0-blue)
![language](https://img.shields.io/badge/written%20in-Caustic-orange)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![tests](https://img.shields.io/badge/tests-151%20unit%20%2B%20127%20black--box-success)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

The build system for the Caustic toolchain, written entirely in Caustic.

Reads a `Causticfile` and drives the Caustic compiler to build targets, run
scripts, and resolve dependencies — no `make`, `cmake`, `gcc`, or any external
tool. The compiler carries its own assembler and linker, so a build never
shells out to `as`/`ld` either.

```bash
caustic-mk build all -j 8     # everything, in parallel, skipping what is current
caustic-mk why kernel         # why does it think that needs rebuilding?
caustic-mk doctor             # which toolchain am I about to use, and is it usable?
```

## Build

Built by the toolchain itself (bootstrapped from an existing `caustic`):

```bash
# From the parent Caustic checkout:
./caustic-mk build caustic-mk    # builds ./caustic-mk
```

`caustic-mk` lives inside a Caustic checkout — its sources `use "../../std/…"` —
so building it needs the parent repo present, as with the assembler and the
linker. See [Development](#development) for the test suites and the gate.

## Usage

```bash
./caustic-mk build <target>     # build one target from the Causticfile
./caustic-mk build all          # build every target (declaration order)
./caustic-mk build all -j 8     # build 8 targets at once (default = CPU count)
./caustic-mk run <name>         # run a named script (or target)
./caustic-mk run <name> -- a b  # forward arguments ($1..$n / $@, or the binary's argv)
./caustic-mk build              # build the project's `default` target
./caustic-mk test               # run the 'test' script
./caustic-mk list               # what this Causticfile declares
./caustic-mk info <target>      # the exact commands a build would run
./caustic-mk why <target>       # why it is (or is not) up to date
./caustic-mk graph [target]     # the dependency tree (--dot for graphviz)
./caustic-mk doctor             # check the toolchain, the manifest and its inputs
./caustic-mk watch [target]     # rebuild whenever an input changes
./caustic-mk install [target]   # copy outputs to their install path / --prefix
./caustic-mk clean [--cache]    # remove build artifacts (--cache: only the cache)
./caustic-mk completions bash   # a completion script carrying this manifest's names
./caustic-mk init               # scaffold a new Causticfile
./caustic-mk --version          # what this binary is
```

Flags on `build`:

| Flag | Meaning |
|------|---------|
| `-j N`, `--parallel N` | build N targets at once (default: CPU count, respecting `taskset`/cgroup limits) |
| `--incremental` | separate compilation with per-module `.csti` interfaces and link-time DCE |
| `--continue` | attempt every target instead of stopping at the first failure |
| `--force` | rebuild even when the output looks up to date |
| `--profile <name>` | apply a `profile` block |
| `--target=<triple>` | override the target triple (own output + cache directory) |
| `-n`, `--dry-run` | print the commands, change nothing on disk |
| `-q`, `--quiet` | errors only (the tools are silenced too) |
| `-v`, `--verbose` | full commands plus the environment handed to the shell |
| `--time` | per-target and total wall clock |
| `--prefix <dir>` | `install` destination root |
| `--interval <ms>` | `watch` poll interval (default 400) |
| `--define NAME=VALUE` | override a `set` from the command line (repeatable) |
| `--cache` | on `clean`: drop the cache and keep the outputs |
| `--dot` | on `graph`: graphviz instead of a tree |

A `Causticfile` is looked for in the current directory and then in each parent,
so the commands work from anywhere inside a project — as `git` does. (Linux
only: `std/os` has no Windows `chdir` binding yet, so on Windows run from the
project root.)

### Only rebuilding what changed

A target is skipped when its output is newer than every input: the source, its
whole import closure, the extra link inputs, the `Causticfile`, and the compiler
binary itself.

```
$ caustic-mk build all
all: 75 built
$ caustic-mk build all          # nothing touched
up to date: build/shell.cse
... 75 lines ...
```

The import closure comes from the compiler's `--emit-deps`, which costs about
half a build, so the list is cached under `.caustic/` and re-emitted only after
something actually changes. `--force` skips the whole question.

Parse errors carry a location, so an editor can jump to them:

```
Causticfile:34:5: error: unknown target key 'sorce' in target 'wterm'
Causticfile:12:12: error: unclosed '{' for target 'shell' — 'target' at line 19 starts a new block
```

## Causticfile

A project is described by a `Causticfile` in its root:

```
name "myproject"
version "0.1.0"
author "you"

target "myapp" {
    src "src/main.cst"
    out "myapp"
}

// A script is a list of commands run in order, through the platform shell.
script "dist" {
    "mkdir -p out"
    "./caustic src/main.cst -O2 -o out/myapp"
    "echo done"
}
```

There is no cap on how many targets, scripts, commands per script, or `system`
libs a Causticfile may declare — the tables grow as it is parsed.

### Target keys

| Key | Repeatable | Meaning |
|-----|------------|---------|
| `src "path.cst"` | | the main Caustic source |
| `out "path"` | | output path (default `<out_dir>/<target>`) |
| `flags "…"` | | flags for the **compiler** |
| `ldflags "…"` | | flags for **caustic-ld** (`--strip`, `--entry=`, `--base=`, …) |
| `asflags "…"` | | flags for **caustic-as** |
| `source "path.cst"` | ✓ | extra Caustic module, compiled `--module-only` and linked in |
| `asm "path.s"` | ✓ | hand-written assembly, run through `caustic-as` |
| `obj "path.o"` | ✓ | prebuilt object, linked as-is |
| `depends "target"` | ✓ | another target to build first |
| `depend "n" in "url" [tag "v"]` | ✓ | git dependency |
| `before "script"` / `after "script"` | ✓ | script to run before the build / after it succeeds |
| `install "path"` | | destination for `caustic-mk install` |
| `version_file "path.cst"` | | generate a `VERSION` module from the project `version` |
| `mode` / `extension` | | CSE output flavour (`--target=caustic-x86_64`) |
| `allow_unsupported "1"` | | pass `--allow-unsupported` |
| `env` / `env_default` | ✓ | environment for this target's build steps |

`source`, `asm` and `obj` accept a wildcard in the last path component, expanded
in alphabetical order so the link order is the same everywhere:

```
asm "kernel/*.s"        # instead of three lines
```

A pattern that matches nothing is an error, not an empty list.

### Project keys

Declared once at the top level and inherited by every target. Flag lists
concatenate (project, then profile, then target — so a target's own flag comes
last and wins); single-valued settings take the narrowest declaration.

| Key | Meaning |
|-----|---------|
| `name` / `version` / `author` / `license` | project metadata (`version` also becomes `--app-version=`) |
| `flags` / `ldflags` / `asflags` | inherited by every target |
| `mode` / `extension` / `allow_unsupported` | inherited CSE output settings |
| `out_dir "dir"` | where a target with no `out` lands (default `build`) |
| `toolchain "dir"` | where `caustic`, `caustic-as`, `caustic-ld` live |
| `prefix "dir"` | default `install` destination |
| `system "lib"` | a `-l` for the link step |
| `depend "n" in "url"` | git dependency shared by every target |
| `env` / `env_default` | environment for every build step and script |
| `include "path"` | merge another Causticfile |
| `profile "name" { … }` | a named settings overlay, selected with `--profile` |
| `set NAME "value"` | a variable, referenced as `$NAME` / `${NAME}` (see [Variables](#variables)) |
| `default "target"` | what a bare `caustic-mk build` builds |
| `when <os\|target> == "v" { … }` | a block that only applies when the condition holds |

This is what makes a large project's manifest readable — 75 CausticOS programs
share one line instead of repeating a triple 75 times:

```
flags "--target=caustic-x86_64"

target "shell" { src "shell/shell.cst" out "build/shell.cse" }
target "echo"  { src "coreutils/echo.cst" out "build/echo.cse" }
...
```

**Toolchain discovery.** The tools are looked for in `toolchain "dir"`, then
`./`, then `$CAUSTIC_DIR`, then the directory holding `caustic-mk` itself, then
`PATH`. `./` comes before `$CAUSTIC_DIR` on purpose: a bootstrap build inside the
compiler's own repo must use the binary in the working tree.

### Variables

`set NAME "value"` at the top level, referenced as `$NAME` or `${NAME}` in any
string value — the way a manifest with many similar targets stops repeating
itself:

```
set TRIPLE "caustic-x86_64"
set OUTDIR "build/$TRIPLE"

flags "--target=$TRIPLE"
target "shell" { src "shell/shell.cst" out "$OUTDIR/shell.cse" }
```

`--define NAME=VALUE` overrides a `set` for one invocation, and `set` will not
clobber it — so a single manifest serves a matrix:

```bash
caustic-mk build all --define TRIPLE=windows-x86_64
```

**Only names declared by `set` (or `--define`) are substituted. Every other `$`
passes through untouched.** That is what keeps the feature from colliding with
the two places `$` already means something to someone else: a script command
runs through `/bin/sh`, where `$1`, `$@`, `$HOME` and the `$2` in
`awk '{print $2}'` belong to the shell, and `flags "--path $CAUSTIC_DIR/std"`
relies on the shell expanding an `env` variable at build time. Write `$$` where
a declared name must *not* be substituted.

### Conditional blocks

```
when os == "windows" { system "ws2_32" }
when target == "caustic-x86_64" { extension "cse" }

target "net" {
    src "net.cst"
    out "build/net"
    when os == "linux"   { flags "-O2" }
    when os == "windows" { flags "-O0" }
}
```

Evaluated **while parsing**, at project and at target scope. The inactive arm is
not skipped at build time — it never becomes part of the project at all, which is
the manifest's version of the `os.current == os.OS_X` dispatch the language
itself uses. `os` is the host running `caustic-mk`; `target` is the effective
triple from `--target=`. The `==` may be omitted.

### Profiles

```
profile "release" { flags "-O2" }
profile "debug"   { flags "-O0" }
```

```bash
caustic-mk build caustic --profile release
```

Each profile gets its own cache directory (`.caustic/release/`), so a release
object can never satisfy a debug build. A profile accepts `flags`, `ldflags`,
`asflags`, `mode`, `extension` and `out_dir`.

### Asking questions instead of guessing

```
$ caustic-mk why caustic-mk
caustic-mk: rebuild needed
  out           caustic-mk  2026-07-25 18:22:15
  newer         core/sysutil.cst  2026-07-25 18:31:02  [import closure]
```

`why` runs the same up-to-date check a build runs and reports the input that
decided it — the question a bare "up to date" cannot answer. The kind in
brackets says where it came from: `src`, `declared input`, `import closure`,
`manifest` or `compiler`.

`graph [target]` prints the dependency tree a build walks, marking groups and
cycles; `--dot` emits graphviz instead.

`doctor` checks what a build is about to depend on, before it costs a failure:
which `caustic` / `caustic-as` / `caustic-ld` was found **and by which rule**
(`toolchain`, `./`, `$CAUSTIC_DIR`, `caustic-mk`'s own directory, `PATH`), that
every declared `src` / `source` / `asm` / `obj` exists, that every `depends` and
hook names something real, that the cache is writable, and that `git` is present
if the manifest has `depend` entries. It exits non-zero only on real problems.

### Cross-building

```bash
caustic-mk build all --target=windows-x86_64
```

overrides the triple from `flags` and gives that triple its own output and cache
directories (`build/windows-x86_64/…`, `.caustic/windows-x86_64/`), so several
triples coexist without clobbering each other.

### include

```
include "userspace/Causticfile"
```

Merges another manifest's targets, scripts and dependencies. Its path-valued
keys are resolved relative to **it**, so a subdirectory's Causticfile needs no
rewriting to be included from above. Paths embedded in `flags` text (`--path
kernel`) are not rewritten — spell those relative to the top level. Include
cycles are an error.

### install

```
prefix "/usr/local"                 # project-wide default

target "caustic" {
    src "src/main.cst"
    out "caustic"
    install "bin/caustic"           # -> /usr/local/bin/caustic
}
```

`--prefix <dir>` overrides the project's; a relative `install` path hangs off the
prefix, an absolute one is used as-is. The mode follows the source, so an
executable stays executable and a data file does not become one.

A target with no `install` key lands in `<prefix>/bin/<name>` — a prefix is the
root of a hierarchy (`bin/`, `lib/`, `share/`), so putting a binary directly in
it would leave it where no `PATH` looks.

### Hooks

```
target "shell" {
    src "shell/shell.cst"
    out "build/shell.cse"
    after "make-init"               # only runs if the build succeeded
}

script "make-init" {
    "cp build/shell.cse build/init.cse"
}
```

A target that declares `source` / `asm` / `obj` / `ldflags` is built by the
**staged pipeline** — compile, assemble, link as separate steps — because the
compiler's one-shot mode links exactly one object and rejects linker-only flags
like `--strip`. This is what a kernel needs:

```
target "kernel" {
    src "kernel/main.cst"
    out "build/kernel.elf"
    flags "--path kernel --path kernel/arch --path kernel/mm"
    asm "kernel/cdvrspec_data.s"
    asm "kernel/smp_asm.s"
    asm "kernel/syscall_entry.s"
    ldflags "--strip --freestanding --entry=_kernel_start --base=0xFFFFFFFF80000000"
}
```

which runs:

```
caustic -c kernel/main.cst <flags>      -> kernel/main.cst.s
caustic-as kernel/main.cst.s            -> kernel/main.cst.s.o
caustic-as kernel/<each>.s              -> kernel/<each>.s.o
caustic-ld <all objects> <ldflags> -o build/kernel.elf
```

Objects reach the linker in declaration order, main source first. `--incremental`
links the same set (per-module objects + the target's extra inputs).

`source` is for a module the main source does **not** `use` — one reached only
from hand-written assembly, say. Modules pulled in by `use` are already part of
the main object; listing them would duplicate their symbols.

A `--target=` in `flags` is forwarded to the assemble and link steps. Staged
builds are therefore limited to targets `caustic-as` can assemble (ELF and CSE
today — it rejects `windows-x86_64`), so a PE target stays on the one-shot path.

### Groups and `build all`

`build all` builds every target in declaration order. A target reached as
someone else's dependency is built once, so shared dependencies aren't rebuilt
per consumer. Without `--continue` it stops at the first failure; with it,
everything is attempted and the summary says how many failed.

A group is just a target with only `depends`:

```
target "toolchain" {
    depends "caustic"
    depends "caustic-as"
    depends "caustic-ld"
}
```

`caustic-mk build toolchain` builds the three and nothing else. A Causticfile
that declares its own `target "all"` keeps it — `build all` only means
"everything" when no such target exists.

### Environment and script arguments

Commands inherit the environment `caustic-mk` was started with (PATH, HOME,
`$CAUSTIC_DIR`, …). `env` / `env_default` declare more, at project, target or
script scope — the narrower scope wins, and `env_default` only applies when the
variable isn't already set:

```
env_default "CAUSTIC_DIR" "../Caustic"
env "HEADLESS" "0"

script "run-wm" {
    env "HEADLESS" "1"                       // overrides the project value
    "bash userspace/build.sh"
    "qemu-system-x86_64 -smp $1 -cdrom $CAUSTIC_DIR/build/os.iso"
}
```

Arguments after `run <name>` (optionally separated by `--`) become the script's
positional parameters:

```bash
./caustic-mk run run-wm -- 2        # $1 = 2, $@ = 2
./caustic-mk run myapp -- --verbose # a target: forwarded to the binary's argv
```

On Linux they are the shell's real positional parameters, so `$1`, `$@`, `$#`
behave as in any shell script — and an `awk '{print $1}'` inside a command is
left alone. On Windows the maker expands `$1`/`$@`/`$VAR` itself, since cmd.exe
has neither.

Command strings understand `\"`, `\\`, `\n` and `\t`, so a command can contain a
double quote or a newline. A string may not span lines — an unterminated one is
reported where it starts, rather than swallowing the next key.

When a command is echoed, control characters are shown as escapes (`\n`, `\t`)
so the line stays a line; the command itself still receives the real bytes:

```
  > printf 'a b c\n' | awk '{print "campo2 =", $2}'
campo2 = b
```

### Command prefixes in a script

Two modifiers, borrowed from make because that is the vocabulary people already
have for exactly these needs:

```
script "tidy" {
    "-rm -f stray.tmp"          // '-' — run it, ignore a non-zero exit
    "@echo done"                // '@' — run it without echoing the line
}
```

Both may be combined (`-@cmd`). Without them a script had no way to express
either: one `rm -f` of a file that happened not to exist aborted the whole
script, and every command was echoed whether or not it printed its own message.

### Dependencies

```
# Git dependency, pinned to a tag — valid at the top level (shared by every
# target) or inside one target.
depend "somelib" in "https://github.com/user/somelib" tag "v1.0.0"
```

`caustic-mk` clones the dependency and makes it importable from your `.cst`
sources. Everything resolves through the Caustic toolchain — there is no
external package manager in the loop.

### What `clean` removes

Everything a build writes, not just the two well-known directories: each
target's `out` (wherever it points), the `<src>.s` / `<src>.s.o` pair the staged
pipeline leaves beside every compiled source, any generated `version_file`, the
cache directory, and `out_dir`. `--dry-run` lists what would go.

## Architecture

| File | Lines | Purpose |
|------|------:|---------|
| `main.cst` | 474 | CLI entry point, option parsing, command dispatch |
| `parser/cfile_lexer.cst` | 291 | `Causticfile` tokens and every diagnostic's `file:line:col` |
| `parser/parser.cst` | 1442 | the manifest: keys, targets, scripts, profiles, variables, `when` |
| `exec/build.cst` | 1650 | the three build paths, up-to-date check, object cache, `-j`, `why`, `graph` |
| `exec/scripts.cst` | 419 | `run` / `test` / `list` / `install` / `clean` / `init` |
| `exec/doctor.cst` | 331 | `doctor` and `completions` |
| `exec/deps.cst` | 150 | git dependency resolution |
| `core/common.cst` | 673 | strings, paths, globs, hashes, the shared heap |
| `core/sysutil.cst` | 902 | subprocess, filesystem, toolchain discovery, output control |
| `version.cst` | 2 | the version `--version` reports, kept in step by `version_file` |

Roughly 6.3k lines of Caustic, plus 865 lines of tests and 641 of shell tooling.

## Development

```bash
tools/install-hooks.sh        # once — installs the pre-commit gate
tools/precommit.sh            # the whole gate, by hand
caustic-mk test               # just the two suites
tools/check-cross.sh          # opt-in: the Windows binary under wine
tools/prerelease.sh           # version bookkeeping, before tagging
```

`tools/precommit.sh` is the gate the hook runs, and what it proves is specific:

1. the compiler works at all;
2. `caustic-mk` builds from source;
3. **that maker builds the maker, twice, byte-identically** — a maker built by a
   maker is the same binary, so its own build path is deterministic;
4. **one-shot, staged and `--incremental` all produce a working program** — the
   maker's three build paths, the analogue of the parent repo's `-O0/-O1/-O2`
   differential;
5. both suites pass;
6. nothing was written into the working tree.

The suites are two layers:

- **`tests/run_tests.cst`** — 151 unit checks over the pure helpers in `core/`
  and the manifest interpolator: the glob matcher, the path splitters (both
  separators and drive letters), the comparator that gives the link its
  determinism, the cache-key hashes, the shell quoter, the command echo,
  `write_if_changed`, the date formatter, `parse_int_strict`.
- **`tests/integration.sh`** — 127 black-box cases over
  `tests/fixtures/<case>/Causticfile`, one per defect the maker has actually
  shipped: dependency failure propagating through `--continue`, the object cache
  distinguishing identical content at different paths, `run` not picking up a
  binary from `PATH`, nested `out`, duplicate names, an unclosed brace, glob
  order, profile cache separation, `install` composing with `--prefix`, hook
  ordering, `--dry-run` touching nothing. Every case runs on a copy of its
  fixture in `$TMPDIR`, so a build never writes into the repo.

There is no CI service: the gate is a shell script and a git hook, which is how
the parent repo does it too. On a machine with a global `core.hooksPath`,
`tools/install-hooks.sh` will say so — a repo-local hook is shadowed by it — and
offers `--dispatch` to add a delegating dispatcher rather than writing into a
shared directory on its own.

Conventions worth knowing before editing: grow a table **before** taking a
pointer to an element, `cast(i32, 0 - 1)` for a `-1` returned as `i32`,
`with mut` on anything assigned after its declaration, `c.big_alloc` rather than
`galloc` for anything whose size follows the manifest (`mem.bins` caps one
allocation at 64 KiB), `io.*` in preference to shelling out, and every manifest
error carrying `Causticfile:line:col`. An OS guard must be the **whole**
condition of its own `if` — written as `if (rc == 0 && os.current() == ...)` the
compiler cannot dead-strip the branch, and the wrong platform's syscalls survive
into the binary.

## License

MIT — see [LICENSE](LICENSE). Part of the [Caustic](https://github.com/Caua726/Caustic)
project, which is MIT throughout.
