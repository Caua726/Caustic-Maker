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
./caustic-mk build <target> -j 8   # parallel build (default = CPU cores)
./caustic-mk run <name>         # run a named script (or target)
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

# A script is a list of shell-free build steps run in order.
script "dist" {
    "mkdir -p out"
    "./caustic src/main.cst -O2 -o out/myapp"
    "echo done"
}
```

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
