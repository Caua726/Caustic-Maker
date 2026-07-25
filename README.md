# caustic-mk

The build system for the Caustic toolchain, written entirely in Caustic.

Reads a `Causticfile` and drives the Caustic compiler to build targets, run
scripts, and resolve dependencies — no `make`, `cmake`, `gcc`, or any external
tool. The compiler carries its own assembler and linker, so a build never
shells out to `as`/`ld` either.

## Build

Built by the toolchain itself (bootstrapped from an existing `caustic`):

```bash
# From the repo root:
./caustic-mk build caustic-mk    # builds ./caustic-mk
```

## Usage

```bash
./caustic-mk build <target>     # build one target from the Causticfile
./caustic-mk build all          # build every target (declaration order)
./caustic-mk build all -j 8     # build 8 targets at once (default = CPU count)
./caustic-mk run <name>         # run a named script (or target)
./caustic-mk run <name> -- a b  # forward arguments ($1..$n / $@, or the binary's argv)
./caustic-mk test               # run the 'test' script
./caustic-mk list               # what this Causticfile declares
./caustic-mk info <target>      # the exact commands a build would run
./caustic-mk watch [target]     # rebuild whenever an input changes
./caustic-mk install [target]   # copy outputs to their install path / --prefix
./caustic-mk clean              # remove build artifacts
./caustic-mk init               # scaffold a new Causticfile
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
prefix, an absolute one is used as-is. The executable bit is preserved.

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

| File | Purpose |
|------|---------|
| `main.cst` | CLI entry point and command dispatch |
| `parser/` | `Causticfile` lexer and parser |
| `exec/build.cst` | Target building (invokes the compiler) |
| `exec/deps.cst` | Dependency resolution |
| `exec/scripts.cst` | Scripts and lifecycle (`run`, `test`, `list`, `install`, `clean`, `init`) |
| `core/` | Shared helpers, subprocess/FS layer, single-heap runtime |

## License

Part of the [Caustic](https://github.com/Caua726/Caustic) project.
