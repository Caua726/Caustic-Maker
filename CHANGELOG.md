# Changelog

All notable changes to `caustic-mk`. Versions follow the tags on this repo; the
version lives in both `version.cst` and the `Causticfile`, and
`tools/prerelease.sh` refuses a release when they disagree.

## Unreleased

Found while building and publishing the 0.2.0 artifacts.

### Fixed

15. **`install` with only `--prefix` dropped the binary in the prefix root.**
    A prefix is the root of a hierarchy (`bin/`, `lib/`, `share/`), so a target
    with no `install` key now lands in `<prefix>/bin/<name>` instead of
    `<prefix>/<name>` — where no `PATH` looks.
16. **`--target=` created the triple directory in the project root.** It hung the
    directory off the target's `out`; for a manifest whose outputs are bare names
    (`out "caustic-mk"`) that is the root, so cross-building four triples dropped
    four directories next to the sources. It now falls back to `out_dir`, which
    is what the README already promised.
17. **A PE build's `.pdb` was orphaned.** `caustic-ld` names the CodeView sidecar
    after the output it was given — the temp name — so every Windows build left a
    stray `<out>.tmp.pdb` and the `<out>.pdb` a debugger looks for never existed.
    It now follows the rename, and is removed when the build fails.
18. **`tools/prerelease.sh` compared against stale tags.** It read `git tag`
    without fetching, so a tag pushed from another checkout was invisible — it
    once compared 0.2.0 against v0.1.1 while v0.1.2 already existed on the
    remote. It fetches first, and says so when it cannot.

## 0.2.0

The round that gave the maker an immune system. 4.7k lines of build system had no
tests, no gate and no hooks; the fixes from 0.1.1 were a snapshot that nothing
protected. This adds the two suites, the `tools/` gate, and the features a large
manifest needs — plus the fourteen bugs found along the way, two of them by the
new tooling on its first run.

### Added — testing and tooling

- **`tests/run_tests.cst`** — 151 unit checks over the pure helpers in `core/`
  and the manifest interpolator: the glob matcher (including the backtracking
  cases), the path splitters on both separators and drive letters, the
  comparator that gives the link its determinism, the cache-key hashes, the
  shell quoter, the command echo, `write_if_changed`, the date formatter and
  `parse_int_strict`.
- **`tests/integration.sh` + `tests/fixtures/`** — 127 black-box cases, one per
  defect the maker has actually shipped. Each runs on a copy of its fixture in
  `$TMPDIR`, so a build never writes into the repo.
- **`tools/precommit.sh`** — the gate: the compiler works, `caustic-mk` builds
  from source, **that maker builds the maker twice byte-identically**, all three
  build paths (one-shot / staged / `--incremental`) produce a working program,
  both suites pass, and nothing was written into the working tree.
- **`tools/prerelease.sh`** — version bookkeeping: the two sources agree, the
  version moved past the last tag, the tag is free, `version.cst` is tracked.
- **`tools/check-cross.sh`** — opt-in: cross-compiles `caustic-mk.exe` and
  exercises it under wine. Skips cleanly without wine, never gates a commit.
- **`tools/install-hooks.sh`** — installs the hooks in the right place, which for
  a submodule is *not* `.git/hooks`. Detects a global `core.hooksPath` shadowing
  the repo's hooks and offers a delegating dispatcher instead of writing into a
  shared directory unasked.

### Added — build system

- **`why <target>`** — the up-to-date decision with the input that made it, and
  what kind of input it was (`src`, `declared input`, `import closure`,
  `manifest`, `compiler`). Runs the same check a build runs, so the two cannot
  disagree.
- **`graph [target]`** — the dependency tree a build walks, marking groups and
  cycles; `--dot` for graphviz.
- **Object cache GC** — objects the build superseded are swept after a successful
  link. `clean --cache` drops the cache and keeps the outputs.
- **Concurrent steps within a target** — the `asm` / `source` inputs of one
  target are compiled and assembled in parallel. Measured ~7% on the causticos
  kernel (3 `.s` files), whose cost is dominated by its single large compile;
  the `--incremental` per-module loop deliberately stays serial, because each
  module reads its dependencies' `.csti`.
- **`default "target"`** — what a bare `caustic-mk build` builds.

### Added — manifest language

- **`set NAME "value"` + `$NAME` / `${NAME}`** interpolation in every string
  value. Only declared names are substituted; every other `$` passes through, so
  `$1`, `$@`, `$HOME` and `awk '{print $2}'` still belong to the shell. `$$` is a
  literal `$`.
- **`--define NAME=VALUE`** — overrides a `set` for one invocation, and `set`
  will not clobber it, so one manifest serves a build matrix.
- **`when os == "..." { … }` / `when target == "..." { … }`** — conditional
  blocks at project and target scope, evaluated while parsing. The inactive arm
  never becomes part of the project. `==` is optional.

### Added — diagnostics and workflow

- **`doctor`** — which toolchain was found and by which rule, whether every
  declared input exists, whether every `depends` / hook / `default` resolves,
  whether the cache is writable, whether `git` is present when the manifest needs
  it. Exits non-zero only on real problems.
- **"did you mean"** — an edit-distance suggestion for an unknown target, script
  or `run` name. Silent when nothing is close, because a wrong guess is worse
  than none.
- **`--version` / `-V`** — reads `version.cst`.
- **`completions bash|zsh`** — a completion script carrying the current
  manifest's own target and script names.
- **`-` and `@` prefixes on a script command** — ignore a non-zero exit, and do
  not echo the line. make's vocabulary, for the two needs a script had no way to
  express.

### Fixed

1. **`write_if_changed` rewrote every file ≥512 bytes.** It compared against
   `read_small_file`, which reads at most 511 — so the lengths could never match
   and the function rewrote every time, touching the mtime and defeating the
   up-to-date check it exists to protect.
2. **A glob failure was reported as "no file matches".** `io.list_dir` returns
   -1 for a missing directory and on every Windows host; collapsing that into 0
   sent the reader to check their own file names instead of the missing
   capability.
3. **`glob_expand` leaked its entry buffer** on the success path.
4. **`abs_path` treated a Windows absolute path as relative**, turning
   `C:\proj\x.cst` into `<cwd>/C:\proj\x.cst`.
5. **`basename` split only on `/`**, disagreeing with `path_dirname`, which
   always accepted both separators.
6. **`path_join` considered only a `/`-leading path absolute** — the same
   inconsistency in the other direction.
7. **`remove_dir` spliced an unquoted path into `rm -rf`.** A project under a
   directory with a space in its name deleted the wrong thing, or nothing.
8. **`copy_file` chmod'ed every installed file 0755**, so an installed data file
   came out executable. The mode now follows the source.
9. **`-j` and `--interval` accepted anything.** `-j abc` parsed as 0, which
   means "auto-detect" — a typo silently changed the build.
10. **`.caustic/obj/` grew by one file per edit, forever.** Nothing pruned it;
    the only remedy was `clean`, which throws away the whole warm cache.
11. **The version disagreed with itself.** The Causticfile said 0.1.0 while
    `version.cst` and the latest tag said 0.1.1, and no flag existed to settle
    it. Now aligned, tracked, and checked by `tools/prerelease.sh`.
12. **Build litter in the working tree** — a 490 KB `main.cst.s` and an orphan
    `version.cst` from the old always-on generator.
13. **`caustic-mk` could not be built for Windows at all.** The guard
    `if (rc == 0 && os.current() == os.OS_LINUX)` folds `os.current()` to a
    literal but leaves the `&&` non-literal, so dead-branch elimination never
    fired: `os.linux.chmod` survived into the Windows build and its `syscall`
    was rejected at codegen. Found by `tools/check-cross.sh` on its first run.
    The maker now cross-compiles and runs under wine.
14. **`-q` invalidated the entire object cache.** It rode along in the compile
    tail, and the tail is hashed into the object key — so one quiet build
    followed by a loud one recompiled every module, for a flag that changes no
    generated byte.

### Documentation

- README: badges, the new commands and keys, a `Development` section covering the
  gate and both suites, an architecture table with real line counts, and the
  license stated as MIT.
- `CLAUDE.md`: the architecture map and the conventions that cost an hour to
  rediscover — including the whole-condition OS guard from bug 13 and the
  one-second mtime granularity the fixtures have to account for.
- `CONTRIBUTING.md` and this changelog: new.

## 0.1.1

Correctness sweep and manifest-driven builds: 27 defects fixed and 15 features
added over the previous release. Highlights — `--continue` no longer reports
success for a build whose dependency failed; the object cache is keyed on path
and flags rather than content alone; `run` executes the project's output instead
of whatever `PATH` resolves; `mkdir_p` creates parents; the `mv` / `rm -rf` /
`/dev/null` calls that made the incremental path silently Linux-only are gone;
every manifest error carries `Causticfile:line:col`; duplicate names and unclosed
braces are errors instead of silent shadowing. Added `-j N` parallel builds,
mtime-based up-to-date skipping, project-wide flag inheritance, toolchain
discovery, `list`, `info`, `--dry-run`, `-q`/`-v`/`--time`, `before`/`after`
hooks, `install`, globs in `source`/`asm`/`obj`, `include`, `profile`,
`--target=`, and `watch`.

## 0.1.0

Multi-object targets, unbounded tables (no `MAX_TARGETS` / `MAX_SCRIPTS` /
`MAX_CMDS`), script environments and arguments, and `build all`.
