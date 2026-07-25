# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commit Policy (IMPORTANT)

When creating git commits in this repository:

- **Do NOT add a `Co-Authored-By:` trailer** of any kind (no Claude, no Anthropic, no AI co-author).
- **Do NOT mention Claude, Anthropic, or any AI assistant** anywhere in the commit message — no "Generated with Claude Code" footer, no `https://claude.ai/code/...` session link, no "🤖" markers.
- Write commit messages as if authored solely by the human maintainer. Describe the change only.

This overrides any default commit-attribution behavior.

## What this is

`caustic-mk`: the build system for the Caustic toolchain, written in Caustic.
Reads a `Causticfile`, drives `caustic` / `caustic-as` / `caustic-ld`. No make,
no cmake, no shell build scripts.

**This repo is normally a submodule of the Caustic repo, and needs to be.** Its
sources `use "../../std/io.cst"` — the same convention the assembler and linker
use — so the parent checkout must be present to build. Two consequences worth
remembering: a standalone clone cannot be built, and the git hook directory is
`<parent>/.git/modules/caustic-maker/hooks`, not `.git/hooks`.

## Commands

```bash
# From the parent Caustic checkout:
./caustic-mk build caustic-mk    # build this

# From here:
tools/install-hooks.sh           # once — install the pre-commit gate
tools/precommit.sh               # the whole gate by hand
caustic-mk test                  # just the two suites
tools/check-cross.sh             # opt-in: the Windows binary under wine
tools/prerelease.sh              # version bookkeeping before a tag
```

## Architecture

| File | Purpose |
|------|---------|
| `main.cst` | CLI entry, `struct Opts`, option parsing, command dispatch |
| `parser/cfile_lexer.cst` | tokens, and every diagnostic's `file:line:col` |
| `parser/parser.cst` | the manifest: keys, targets, scripts, profiles, variables, `when` |
| `exec/build.cst` | three build paths, up-to-date check, object cache, `-j`, `why`, `graph` |
| `exec/scripts.cst` | `run` / `test` / `list` / `install` / `clean` / `init` |
| `exec/doctor.cst` | `doctor` and `completions` |
| `exec/deps.cst` | git dependency resolution |
| `core/common.cst` | strings, paths, globs, hashes, the shared heap |
| `core/sysutil.cst` | subprocess, filesystem, toolchain discovery, output control |
| `version.cst` | the version `--version` reports; tracked, kept in step by `version_file` |
| `tests/run_tests.cst` | unit suite over the pure helpers |
| `tests/integration.sh` + `tests/fixtures/` | black-box cases, one per shipped defect |
| `tools/*.sh` | the gate: precommit, prerelease, check-cross, install-hooks |

### The three build paths

Every change to building has to be checked against all three, which is what the
gate's differential step is for:

- **one-shot** — `caustic src -o out`; the compiler links its single object.
- **staged** — compile / assemble / link as separate steps. Chosen when the
  target declares `source`, `asm`, `obj`, `ldflags` or `asflags`, because the
  one-shot mode links exactly one object and rejects linker-only flags.
- **`--incremental`** — per-module objects cached under `.caustic/obj/`, keyed on
  the module's path ⊕ content ⊕ compile flags ⊕ the compiler's own identity.

## Conventions

These are the ones that cost an hour to rediscover:

- **Grow a table before taking a pointer into it.** `c.big_grow` remaps, so a
  pointer taken before the growth addresses freed pages.
- **`cast(i32, 0 - 1)`** when returning `-1` from an `i32` function: `0 - 1` is
  `i64` and the mismatch is a hard error.
- **`with mut`** on anything assigned after its declaration. Everything is
  immutable by default.
- **`c.big_alloc` / `c.big_grow`, not `galloc`,** for anything whose size follows
  the manifest: `mem.bins` caps a single allocation at 64 KiB, and returns null
  past it. That is why no table has a `MAX_` ceiling.
- **`io.*` in preference to shelling out** when an equivalent exists — a shell
  command is a portability decision, and usually the wrong one.
- **Every manifest error carries `Causticfile:line:col`** via `lx.err_head` /
  `lx.error_at`. A message that says only what is wrong is a hunt in a manifest
  with 75 targets.
- **An OS guard must be the whole condition of its own `if`.** Written
  `if (rc == 0 && os.current() == os.OS_LINUX)`, the compiler folds
  `os.current()` to a literal but the surrounding `&&` is not one, so
  dead-branch elimination never fires — the wrong platform's syscalls survive
  into the binary and codegen rejects them. This is why the maker once could not
  be built for Windows at all.
- **Verbosity must not reach a cache key.** `_compile_tail` is the semantic part
  (hashed into the object key); `_compile_cmd_tail` adds `-q`. Mixing them made
  a quiet build invalidate every cached object.
- **A concurrent batch is only for genuinely independent steps.** `_run_batch`
  runs the `asm`/`source` inputs of one target at once; the `--incremental`
  per-module loop must stay serial, because each module reads its dependencies'
  `.csti`, which an earlier iteration wrote.

## Tests

Add to both layers, and prefer making a new test fail first:

- **unit** (`tests/run_tests.cst`) for anything pure in `core/` or the
  interpolator. `_check`, `_check_str`, `_check_int`; the summary line must say
  `ALL PASSED` for the gate to accept it.
- **black-box** (`tests/fixtures/<case>/Causticfile` + a step in
  `tests/integration.sh`) for anything that needs a process, a directory tree or
  a cache. Every case runs on a copy of its fixture in `$TMPDIR` — a test that
  writes into the repo fails the gate's last step.

Two things the fixtures have to account for: `io.mtime` has **one-second**
granularity and the up-to-date check treats "same second as the output" as
changed, so a build followed immediately by a rebuild always looks stale (date
the fixture's sources into the past instead of sleeping); and the compiler embeds
the **absolute source path**, so the same sources built from two directories
produce different binaries — a fixpoint comparison has to build both generations
in the same directory.

## Manifest variables

`set NAME "value"` + `$NAME` / `${NAME}`, substituted at parse time by
`parser.interpolate`. **Only declared names are substituted; every other `$`
passes through byte for byte** — because `$1`, `$@`, `$HOME` and the `$2` inside
`awk '{print $2}'` belong to the shell, and `flags "--path $CAUSTIC_DIR/std"`
relies on the shell expanding an `env` variable at build time. Erroring on an
unknown name would break both. `$$` yields a literal `$`.

## Version

`version.cst` and the Causticfile's `version` must agree; `tools/prerelease.sh`
blocks a release when they do not, when the version has not moved past the last
tag, or when `version.cst` is untracked. The `version_file "version.cst"` key on
the `caustic-mk` target keeps the file in step, and `--version` reads it.
