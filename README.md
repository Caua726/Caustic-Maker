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
./caustic-mk build <target> -j 8   # parallel build (default = CPU cores)
./caustic-mk run <name>         # run a named script (or target)
./caustic-mk run <name> -- a b  # forward arguments ($1..$n / $@, or the binary's argv)
./caustic-mk test               # run the 'test' script
./caustic-mk clean              # remove build artifacts
./caustic-mk init               # scaffold a new Causticfile
```

Useful flags on `build`:

- `-j N` / `--parallel N` — worker count for parallel emission (0 = auto).
- `--incremental` — separate compilation with per-module `.csti` interfaces and
  link-time DCE (fast rebuilds).
- `--continue` — keep going after a target fails.

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
| `out "path"` | | output path (default `build/<target>`) |
| `flags "…"` | | flags for the **compiler** |
| `ldflags "…"` | | flags for **caustic-ld** (`--strip`, `--entry=`, `--base=`, …) |
| `asflags "…"` | | flags for **caustic-as** |
| `source "path.cst"` | ✓ | extra Caustic module, compiled `--module-only` and linked in |
| `asm "path.s"` | ✓ | hand-written assembly, run through `caustic-as` |
| `obj "path.o"` | ✓ | prebuilt object, linked as-is |
| `depends "target"` | ✓ | another target to build first |
| `depend "n" in "url" [tag "v"]` | ✓ | git dependency |
| `mode` / `extension` | | CSE output flavour (`--target=caustic-x86_64`) |
| `allow_unsupported "1"` | | pass `--allow-unsupported` |
| `env` / `env_default` | ✓ | environment for this target's build steps |

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
double quote.

### Dependencies

```
# Git dependency, pinned to a tag:
depend "somelib" in "https://github.com/user/somelib" tag "v1.0.0"
```

`caustic-mk` clones the dependency and makes it importable from your `.cst`
sources. Everything resolves through the Caustic toolchain — there is no
external package manager in the loop.

## Architecture

| File | Purpose |
|------|---------|
| `main.cst` | CLI entry point and command dispatch |
| `parser/` | `Causticfile` lexer and parser |
| `exec/build.cst` | Target building (invokes the compiler) |
| `exec/deps.cst` | Dependency resolution |
| `exec/scripts.cst` | Script execution (`run`, `test`, `clean`, `init`) |
| `core/` | Shared helpers and single-heap runtime |

## License

Part of the [Caustic](https://github.com/Caua726/Caustic) project.
