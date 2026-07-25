#!/usr/bin/env bash
#
# tools/precommit.sh — caustic-mk's self-check gate.
#
# Run by .git/hooks/pre-commit (install with tools/install-hooks.sh) and safe to
# run by hand. It proves the build system still BUILDS ITSELF and still behaves,
# before a commit is allowed. The maker had no gate at all: 4.7k lines whose only
# validation was someone running a build by hand and looking at the output.
#
# What it checks, in the order that fails fastest:
#   1. the compiler works at all;
#   2. caustic-mk builds from source;
#   3. that maker builds the maker, twice, byte-identically (a maker built by a
#      maker is the same binary — the maker's own build path is deterministic);
#   4. one-shot, staged and --incremental all produce a working program (the
#      maker's three build paths, the analogue of the parent repo's
#      -O0/-O1/-O2 differential);
#   5. both test suites;
#   6. nothing was left behind in the working tree.
#
# It NEVER writes into the repo. Steps 3 and 4 run in a symlink sandbox under
# $TMPDIR (see mk_sandbox), so ./caustic-mk in the checkout is not replaced by a
# half-broken binary in the middle of a commit.
#
# Skip:   PRECOMMIT_SKIP=1 git commit ...     (or  git commit --no-verify)
# Force:  PRECOMMIT_FULL=1 tools/precommit.sh (run even with nothing staged)

set -u
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

# ---- pretty output (mirrors the parent repo's tools/*.sh) ------------------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else B=; G=; R=; Y=; D=; N=; fi
step() { printf "%s\n" "${B}▸ $*${N}"; }
ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
info() { printf "      ${D}%s${N}\n" "$*"; }
die()  { printf "  ${R}✗ %s${N}\n" "$*"
         printf "\n${R}${B}pre-commit FAILED${N} — commit blocked (use ${B}--no-verify${N} to override).\n"
         exit 1; }

if [ "${PRECOMMIT_SKIP:-0}" = "1" ]; then echo "${Y}pre-commit skipped (PRECOMMIT_SKIP=1)${N}"; exit 0; fi

# ---- fast path: nothing relevant staged ------------------------------------
if [ "${PRECOMMIT_FULL:-0}" != "1" ]; then
    STAGED="$(git diff --cached --name-only 2>/dev/null)"
    if [ -n "$STAGED" ] && ! printf "%s\n" "$STAGED" | grep -qE '\.cst$|Causticfile|^tools/|^tests/'; then
        echo "${D}pre-commit: no .cst/Causticfile/tools/tests changes staged — skipping self-check${N}"
        exit 0
    fi
fi

# ---- host guard ------------------------------------------------------------
# The gate spawns processes and compares binaries; it is developed and run on
# Linux. On another host, skip cleanly rather than fail cryptically.
HOST="$(uname -s 2>/dev/null || echo unknown)"
if [ "$HOST" != "Linux" ]; then
    echo "${Y}pre-commit: this gate only runs on Linux (host is ${HOST}).${N}"
    echo "${D}  Cross-target checks live in tools/check-cross.sh.${N}"
    exit 0
fi

# ---- locate the toolchain --------------------------------------------------
# caustic-mk lives inside a Caustic checkout (its sources `use "../../std/…"`),
# so the parent directory is both the stdlib and the natural place to find the
# compiler.
PARENT="$(cd "$ROOT/.." && pwd)"
CC=""
for c in "$PARENT/caustic" "$ROOT/caustic"; do [ -x "$c" ] && { CC="$c"; break; }; done
[ -n "$CC" ] || CC="$(command -v caustic 2>/dev/null || true)"
[ -n "$CC" ] || die "no caustic compiler found (looked in $PARENT, $ROOT and PATH)"
[ -d "$PARENT/std" ] || die "no stdlib at $PARENT/std — caustic-mk needs a Caustic checkout as its parent"

W="$(mktemp -d "${TMPDIR:-/tmp}/caustic-mk-precommit.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

echo "${B}caustic-mk pre-commit self-check${N} ${D}(scratch=$W)${N}"
info "compiler: $CC"

# Snapshot the working tree so step 6 can tell what THIS run added, rather than
# demanding a pristine tree — a developer's own work in progress is not our
# business, a test that writes into the repo is.
git status --porcelain 2>/dev/null | sort > "$W/tree.before"

runrc() { "$@" </dev/null >/dev/null 2>&1; echo $?; }

# ─── 1. the compiler works ─────────────────────────────────────────────────
step "compiler sanity"
PROBE="$W/probe.cst"; printf 'fn main() as i32 { return 42; }\n' > "$PROBE"
"$CC" -q "$PROBE" -o "$W/probe" >/dev/null 2>&1 || die "the compiler cannot build a trivial program"
[ "$(runrc "$W/probe")" = 42 ] || die "the compiler produced a wrong trivial binary"
ok "compiles and runs a trivial program"

# ─── 2. caustic-mk builds from source ──────────────────────────────────────
step "caustic-mk builds from source"
"$CC" -q "$ROOT/main.cst" -o "$W/mk1" >/dev/null 2>&1 || die "caustic-mk failed to compile"
[ "$(runrc "$W/mk1" --help)" = 0 ] || die "the freshly built caustic-mk cannot print its usage"
ok "built and runs  $(sha256sum "$W/mk1" | cut -c1-16)…"

# A sandbox that looks like this repo to the compiler without being it: the
# sources are symlinked in and `std` is symlinked beside them, so the
# `use "../../std/io.cst"` in core/ resolves exactly as it does in the checkout.
# Everything a build writes (the binary, .caustic, the .s files) lands here
# instead of in the working tree.
mk_sandbox() {
    local dir="$1"
    mkdir -p "$dir/mk" || return 1
    ln -sfn "$PARENT/std" "$dir/std" || return 1
    local item
    for item in main.cst version.cst core exec parser; do
        [ -e "$ROOT/$item" ] && ln -sfn "$ROOT/$item" "$dir/mk/$item"
    done
    cat > "$dir/mk/Causticfile" <<EOF
name "caustic-mk"
version "0.1.0"

target "caustic-mk" {
    src "main.cst"
    out "caustic-mk"
}
EOF
}

# ─── 3. the maker builds the maker, deterministically ──────────────────────
# gen2 is built by the maker we just compiled; gen3 by gen2. Byte-identical
# means the maker's flag composition and cache keying do not drift between a
# maker built by the compiler and one built by a maker.
#
# Both generations are built in the SAME sandbox directory on purpose: the
# compiler embeds the absolute source path in the debug line table, so building
# the same sources from two different directories yields two different binaries.
# That is a property of the compiler, not of the maker — comparing across
# directories would report a fixpoint failure that is not one.
step "self-build fixpoint (gen2 == gen3)"
mk_sandbox "$W/s" || die "could not stage the sandbox"
SB="$W/s/mk"
( cd "$SB" && CAUSTIC_DIR="$PARENT" "$W/mk1" build caustic-mk -q ) >/dev/null 2>&1 \
    || die "gen2: the built maker could not build the maker"
[ -x "$SB/caustic-mk" ] || die "gen2 produced no binary"
cp "$SB/caustic-mk" "$W/gen2" || die "could not save gen2"
( cd "$SB" && CAUSTIC_DIR="$PARENT" "$W/gen2" build caustic-mk --force -q ) >/dev/null 2>&1 \
    || die "gen3: the gen2 maker could not build the maker"
cp "$SB/caustic-mk" "$W/gen3" || die "could not save gen3"
cmp -s "$W/gen2" "$W/gen3" \
    || die "gen2 != gen3 — the maker's own build path is not deterministic"
MK="$W/gen2"
ok "gen2 == gen3 byte-identical  $(sha256sum "$MK" | cut -c1-16)…"

# ─── 4. the three build paths all work ─────────────────────────────────────
# one-shot (compiler links), staged (compile/assemble/link as separate steps)
# and --incremental (per-module objects). A change that only breaks one of them
# is exactly the kind that ships unnoticed.
step "build paths differential (one-shot / staged / --incremental)"
PATHS="$W/paths"
cp -r "$ROOT/tests/fixtures/paths" "$PATHS" || die "tests/fixtures/paths is missing"
# Date the inputs well into the past. mtime has one-second granularity, and the
# up-to-date check treats "same second as the output" as changed (a source
# written in the same second really can be newer). Without this, a build
# followed immediately by a rebuild always looks stale and the last assertion
# below could never hold — for a reason that has nothing to do with the maker.
touch -d '2001-01-01 00:00:00' "$PATHS"/*.cst "$PATHS/Causticfile" 2>/dev/null || true
( cd "$PATHS" && CAUSTIC_DIR="$PARENT" "$MK" build oneshot -q ) >/dev/null 2>&1 \
    || die "one-shot build failed"
[ "$(runrc "$PATHS/build/oneshot")" = 42 ] || die "the one-shot binary is wrong"
ok "one-shot"
( cd "$PATHS" && CAUSTIC_DIR="$PARENT" "$MK" build staged -q ) >/dev/null 2>&1 \
    || die "staged build failed"
[ "$(runrc "$PATHS/build/staged")" = 42 ] || die "the staged binary is wrong"
ok "staged (compile + assemble + link)"
( cd "$PATHS" && CAUSTIC_DIR="$PARENT" "$MK" build oneshot --incremental --force -q ) >/dev/null 2>&1 \
    || die "incremental build failed"
[ "$(runrc "$PATHS/build/oneshot")" = 42 ] || die "the incremental binary is wrong"
ok "--incremental"

# The up-to-date check is part of the contract: a second build must do nothing.
( cd "$PATHS" && CAUSTIC_DIR="$PARENT" "$MK" build staged 2>&1 ) | grep -q "up to date" \
    || die "a rebuild with nothing changed did not report 'up to date'"
ok "an unchanged rebuild is skipped"

# ─── 5. the test suites ────────────────────────────────────────────────────
step "unit suite (tests/run_tests.cst)"
"$CC" -q "$ROOT/tests/run_tests.cst" -o "$W/unit" >/dev/null 2>&1 || die "the unit suite failed to build"
if ! ( cd "$ROOT" && "$W/unit" > "$W/unit.out" 2>&1 ); then
    tail -20 "$W/unit.out"; die "the unit suite FAILED"
fi
grep -q "ALL PASSED" "$W/unit.out" || { tail -20 "$W/unit.out"; die "the unit suite did not report ALL PASSED"; }
ok "$(grep -oE 'pass=[0-9]+ fail=[0-9]+' "$W/unit.out" | head -1)"

step "integration suite (tests/integration.sh)"
if ! MK="$MK" CAUSTIC_DIR="$PARENT" "$ROOT/tests/integration.sh" > "$W/it.out" 2>&1; then
    tail -30 "$W/it.out"; die "the integration suite FAILED"
fi
ok "$(grep -oE 'pass=[0-9]+ fail=[0-9]+' "$W/it.out" | tail -1)"

# ─── 6. the checks left the working tree alone ─────────────────────────────
# Everything above ran in $W or on a copy of a fixture, so anything that appears
# here was written into the repo by a test — which is how a stray build artifact
# ends up in someone's next commit.
step "working tree"
git status --porcelain 2>/dev/null | sort > "$W/tree.after"
DIRT="$(comm -13 "$W/tree.before" "$W/tree.after" || true)"
if [ -n "$DIRT" ]; then
    printf "%s\n" "$DIRT" | head -10
    die "the checks wrote into the working tree"
fi
ok "unchanged by this run"

printf "\n${G}${B}pre-commit OK${N} — caustic-mk builds itself, all three paths work, both suites pass.\n"
exit 0
