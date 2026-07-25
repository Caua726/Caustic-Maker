# Contributing to caustic-mk

## Getting set up

`caustic-mk` is a submodule of [Caustic](https://github.com/Caua726/Caustic) and
needs the parent checkout: its sources `use "../../std/io.cst"`, the same
convention the assembler and linker follow. Clone the parent with
`--recurse-submodules` and work inside `caustic-maker/`.

```bash
cd Caustic
./caustic-mk build caustic-mk       # build it with the toolchain itself
cd caustic-maker
tools/install-hooks.sh              # once — installs the pre-commit gate
```

If your machine has a global `core.hooksPath` (`git config --get core.hooksPath`),
the repo's hooks are shadowed by it. `install-hooks.sh` says so and offers
`--dispatch` to add a delegating dispatcher; until then, run `tools/precommit.sh`
by hand before committing.

## Before you commit

```bash
tools/precommit.sh
```

That is the gate, and it is what the hook runs. It proves six things: the
compiler works, `caustic-mk` builds from source, that maker builds the maker
twice byte-identically, all three build paths produce a working program, both
suites pass, and nothing was written into the working tree. It never touches the
checkout — the build steps run in a symlink sandbox under `$TMPDIR`.

Skip it once with `PRECOMMIT_SKIP=1 git commit …` or `git commit --no-verify`,
but not habitually: the gate exists because 4.7k lines of build system shipped
27 defects with nothing to catch them.

## Tests come with the change

Both layers, and prefer writing the test **before** the fix so you can watch it
fail:

- **`tests/run_tests.cst`** for anything pure — a path helper, a hash, the glob
  matcher, the interpolator. Use `_check` / `_check_str` / `_check_int`.
- **`tests/fixtures/<case>/Causticfile`** plus a step in `tests/integration.sh`
  for anything that needs a real process, directory tree or cache. Assert with
  `expect_rc` / `expect_out` / `expect_no_out` / `expect_file`.

Two traps the fixtures have to account for:

- `io.mtime` has **one-second** granularity, and the up-to-date check treats
  "same second as the output" as changed. A build followed immediately by a
  rebuild therefore always looks stale — date the fixture's sources into the past
  (`touch -d '2001-01-01' …`) rather than sleeping.
- The compiler embeds the **absolute source path**, so the same sources built
  from two different directories give two different binaries. A fixpoint
  comparison must build both generations in the same directory.

## Conventions

The ones that cost an hour to rediscover are listed in
[`CLAUDE.md`](CLAUDE.md#conventions). The two most load-bearing:

- **Grow a table before taking a pointer into it.** `c.big_grow` remaps.
- **An OS guard must be the whole condition of its own `if`.** Written
  `if (rc == 0 && os.current() == os.OS_LINUX)` the compiler cannot dead-strip
  the branch, and the wrong platform's syscalls survive into the binary. That bug
  made the maker unbuildable for Windows for a whole release.

Also: no new numeric ceiling — anything sized by the manifest grows through
`c.big_grow`; prefer `io.*` to shelling out when an equivalent exists; and every
manifest error carries `Causticfile:line:col`.

## Cross-target

`tools/check-cross.sh` cross-compiles `caustic-mk.exe` and exercises it under
wine. It is opt-in and never gates a commit — but it is the only thing that runs
the Windows branches of the path and subprocess helpers, and it has already
caught a bug that made those branches unreachable. Run it before a release, or
after touching anything under an `os.current()` guard.

## Releases

```bash
tools/prerelease.sh                 # blocks if the bookkeeping is wrong
git tag v<version> && git push origin v<version>
```

The version lives in **two** places — `version.cst` and the `Causticfile` — and
`prerelease.sh` requires them to agree, to be newer than the last tag, and for
`version.cst` to be tracked. Add the release's entry to
[`CHANGELOG.md`](CHANGELOG.md) as part of the same commit.

## Commit messages

Describe the change. No AI-attribution trailers of any kind — see the policy in
[`CLAUDE.md`](CLAUDE.md#commit-policy-important); the `commit-msg` hook enforces
it.
