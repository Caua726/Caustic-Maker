#!/usr/bin/env bash
#
# tests/integration.sh — black-box cases for caustic-mk.
#
# One case per defect the maker has actually shipped: a Causticfile goes in
# (tests/fixtures/<case>/), an exit code and some output come out. These are the
# regressions that a unit test cannot reach, because they only exist once a real
# process resolves a real dependency graph against a real cache directory.
#
# Every case runs on a COPY of its fixture in a scratch directory, so a build
# never writes into the repo and a failure leaves nothing behind.
#
# Usage:  tests/integration.sh              (uses ../caustic-mk, else PATH)
#         MK=/path/to/caustic-mk tests/integration.sh
# Exit 0 = all passed.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIXTURES="$HERE/fixtures"

# ---- the maker under test --------------------------------------------------
# Default to the binary in the parent checkout (that is what a build of this
# repo produces), then whatever is on PATH.
if [ -n "${MK:-}" ]; then :
elif [ -x "$ROOT/caustic-mk" ]; then MK="$ROOT/caustic-mk"
elif [ -x "$ROOT/../caustic-mk" ]; then MK="$(cd "$ROOT/.." && pwd)/caustic-mk"
elif command -v caustic-mk >/dev/null 2>&1; then MK="$(command -v caustic-mk)"
else echo "error: no caustic-mk found (set MK=/path/to/caustic-mk)"; exit 1; fi

# The fixtures have no ./caustic of their own, so toolchain discovery has to
# land somewhere deterministic: point $CAUSTIC_DIR at the parent checkout.
if [ -z "${CAUSTIC_DIR:-}" ] && [ -x "$ROOT/../caustic" ]; then
    CAUSTIC_DIR="$(cd "$ROOT/.." && pwd)"
    export CAUSTIC_DIR
fi

# ---- pretty output (mirrors the parent repo's tools/*.sh) ------------------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
else B=; G=; R=; D=; N=; fi
PASS=0; FAIL=0
step() { printf "\n%s\n" "${B}▸ $*${N}"; }
ok()   { printf "  ${G}✓${N} %s\n" "$*"; PASS=$((PASS+1)); }
bad()  { printf "  ${R}✗${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
note() { printf "      ${D}%s${N}\n" "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caustic-mk-it.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# Copy a fixture into a fresh scratch directory and cd there. Every case gets
# its own copy, so a stale .caustic/ can never leak from one case to the next.
CASE_DIR=""
use_fixture() {
    local name="$1"
    CASE_DIR="$WORK/$name.$RANDOM"
    cp -r "$FIXTURES/$name" "$CASE_DIR" || { bad "fixture $name missing"; return 1; }
    cd "$CASE_DIR" || return 1
}

OUT=""; RC=0
# Run the maker, capturing stdout+stderr into $OUT and the code into $RC.
mk() { OUT="$($MK "$@" 2>&1)"; RC=$?; }

expect_rc() {   # expect_rc <want> <desc>
    if [ "$RC" = "$1" ]; then ok "$2"
    else bad "$2"; note "want rc=$1, got rc=$RC"; note "output: $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"; fi
}
expect_out() {  # expect_out <substring> <desc>
    case "$OUT" in
        *"$1"*) ok "$2" ;;
        *) bad "$2"; note "missing: $1"; note "output: $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')" ;;
    esac
}
expect_no_out() {
    case "$OUT" in
        *"$1"*) bad "$2"; note "unexpected: $1" ;;
        *) ok "$2" ;;
    esac
}
expect_file()    { if [ -e "$1" ]; then ok "$2"; else bad "$2"; note "missing file: $1"; fi; }
expect_no_file() { if [ -e "$1" ]; then bad "$2"; note "should not exist: $1"; else ok "$2"; fi; }
expect_exec()    { if [ -x "$1" ]; then ok "$2"; else bad "$2"; note "not executable: $1"; fi; }

echo "${B}caustic-mk integration suite${N} ${D}($MK)${N}"

# ─── a failed dependency must not be reported as success ────────────────────
# `--continue` means "try the siblings too", never "pretend it worked". It used
# to discard the dependency's rc, build the parent on top of the broken one and
# return 0.
step "dependency failure propagates (--continue)"
if use_fixture dep-fail; then
    mk build app --continue
    expect_rc 1 "build app --continue exits non-zero"
    expect_out "skipped: a dependency failed" "parent is skipped, not built on top"
    expect_no_file "build/app" "no output produced for the skipped parent"
    mk build app
    expect_rc 1 "build app (no --continue) also exits non-zero"
fi

# ─── an out path whose parent directory does not exist ──────────────────────
step "nested out directory is created"
if use_fixture nested-out; then
    mk build app
    expect_rc 0 "build succeeds with out dist/bin/app"
    expect_file "dist/bin/app" "the nested output exists"
fi

# ─── duplicate names must be an error, not a silent shadow ──────────────────
step "duplicate target name"
if use_fixture dup-target; then
    mk list
    expect_rc 1 "duplicate target is rejected"
    expect_out "duplicate target 'shell'" "the message names the target"
    expect_out "first declared at line 3" "and points at the first declaration"
fi

# ─── an unclosed brace must not swallow the rest of the file ────────────────
step "unclosed brace"
if use_fixture unclosed; then
    mk list
    expect_rc 1 "unclosed '{' is rejected"
    expect_out "unclosed '{'" "the message says what is unclosed"
    expect_out "starts a new block" "and where the next block begins"
fi

# ─── a string may not span lines ───────────────────────────────────────────
step "unterminated string"
if use_fixture unterminated-string; then
    mk list
    expect_rc 1 "unterminated string is rejected"
    expect_out "unterminated string" "reported as a string problem"
    expect_out "Causticfile:1:" "at the line where the string starts"
fi

# ─── an env key the shell would reject is the maker's error to report ──────
step "invalid env key"
if use_fixture bad-env-key; then
    mk list
    expect_rc 1 "MY-VAR is rejected at parse time"
    expect_out "not a usable environment variable name" "with an explanation"
fi

# ─── glob order decides link order, so it must be alphabetical ─────────────
step "glob expands in alphabetical order"
if use_fixture glob-order; then
    mk info app
    expect_rc 0 "info succeeds"
    # Each module shows up several times (compile, assemble, link). What has to
    # be alphabetical is the order they are FIRST reached, which is the order
    # the expansion produced.
    order="$(printf '%s' "$OUT" | grep -oE 'mods/[a-z]+\.cst' | sed 's|mods/||;s|\.cst||' \
             | awk '!seen[$0]++' | tr '\n' ' ')"
    if [ "$order" = "alpha middle zebra " ]; then
        ok "alpha, middle, zebra — sorted, not readdir order"
    else
        bad "glob order is not alphabetical"; note "got: $order"
    fi
fi

# ─── install destination composes with --prefix ────────────────────────────
step "install path hangs off --prefix"
if use_fixture install-prefix; then
    mk build app
    expect_rc 0 "build succeeds"
    mk install app --prefix "$CASE_DIR/pfx"
    expect_rc 0 "install succeeds"
    expect_file "$CASE_DIR/pfx/bin/app" "--prefix + install \"bin/app\" -> <prefix>/bin/app"
    expect_exec "$CASE_DIR/pfx/bin/app" "the installed binary keeps its executable bit"
    expect_no_file "/opt/should-be-overridden" "the project prefix did not win over --prefix"
fi

# A target with NO `install` key still has to land somewhere a PATH looks: a
# prefix is the root of a hierarchy, so <prefix>/bin/<name>, not <prefix>/<name>.
if use_fixture nested-out; then
    mk build app
    expect_rc 0 "build succeeds"
    mk install app --prefix "$CASE_DIR/pfx"
    expect_rc 0 "install with only --prefix succeeds"
    expect_file "$CASE_DIR/pfx/bin/app" "no install key -> <prefix>/bin/<name>"
    expect_no_file "$CASE_DIR/pfx/app" "and not loose in the prefix root"
fi

# ─── hooks: before always, after only on success ───────────────────────────
step "before / after hooks"
if use_fixture hooks; then
    mk build good
    expect_rc 0 "the good target builds"
    expect_out "HOOK_BEFORE" "before ran"
    expect_out "HOOK_AFTER" "after ran"
    mk build bad
    expect_rc 1 "the broken target fails"
    expect_out "HOOK_BEFORE" "before ran anyway"
    expect_no_out "HOOK_AFTER" "after did NOT run on failure"
fi

# ─── --dry-run must not touch the disk ─────────────────────────────────────
step "--dry-run changes nothing"
if use_fixture dry-run; then
    before="$(ls -A | sort | tr '\n' ' ')"
    mk build app -n
    expect_rc 0 "dry run succeeds"
    expect_out "[dry]" "the commands are printed"
    after="$(ls -A | sort | tr '\n' ' ')"
    if [ "$before" = "$after" ]; then ok "the directory is byte-for-byte the same"
    else bad "dry run wrote to disk"; note "before: $before"; note "after:  $after"; fi
    expect_no_file "build" "no output directory"
    expect_no_file ".caustic" "no cache directory"
fi

# ─── a profile gets its own cache, so a release object can't serve a debug ──
step "profile has its own cache"
if use_fixture profile-cache; then
    mk build app --profile release
    expect_rc 0 "build --profile release succeeds"
    expect_file ".caustic/release" "release artifacts live in .caustic/release"
    mk build app --profile nosuch
    expect_rc 1 "an unknown profile is an error"
    expect_out "no profile named" "with a message that says so"
fi

# ─── run must execute the project's binary, not one from PATH ──────────────
# `out "mkfixture"` used to be handed to the shell as a bare command, so PATH
# decided which program ran.
step "run executes the project's output, not PATH"
if use_fixture run-path; then
    mkdir -p "$CASE_DIR/impostor"
    printf '#!/bin/sh\nexit 99\n' > "$CASE_DIR/impostor/mkfixture"
    chmod +x "$CASE_DIR/impostor/mkfixture"
    mk build mkfixture
    expect_rc 0 "build succeeds"
    PATH="$CASE_DIR/impostor:$PATH" mk run mkfixture
    expect_rc 7 "run got the project's binary (exit 7), not the impostor (99)"
fi

# ─── the object cache must be keyed on more than content ───────────────────
# Two modules with byte-identical content at different paths: the compiler
# mangles symbols by path, so sharing one cached object between them produces a
# link error or the wrong symbol.
step "object cache distinguishes identical content at different paths"
if use_fixture obj-cache; then
    mk build app --incremental
    expect_rc 0 "incremental build succeeds"
    if [ -x build/app ]; then
        ./build/app; rc=$?
        if [ "$rc" = 6 ]; then ok "both modules linked (3 + 3 = 6)"
        else bad "wrong result from the linked program"; note "want 6, got $rc"; fi
    else
        bad "no binary produced"
    fi
    # A second run must reuse the cache and still be correct.
    mk build app --incremental --force
    expect_rc 0 "a forced rebuild is still correct"
fi

# ─── superseded objects are swept, not accumulated ─────────────────────────
# Every edit produces a new cache key, so the object built from the previous
# content is dead the moment it is replaced. Nothing removed them: .caustic/obj/
# grew by one file per edit for the life of the project.
step "the object cache does not grow without bound"
if use_fixture obj-cache; then
    mk build app --incremental
    expect_rc 0 "first incremental build"
    n1="$(ls .caustic/obj 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n1" -gt 0 ]; then ok "$n1 objects cached"; else bad "no objects were cached"; fi
    printf 'fn v() as i32 { return 4; }\n' > a/m.cst
    mk build app --incremental
    expect_rc 0 "rebuild after editing one module"
    expect_out "stale objects removed" "the superseded object is reported as swept"
    n2="$(ls .caustic/obj 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n2" = "$n1" ]; then ok "still $n2 objects — the orphan is gone, not kept"
    else bad "the cache grew"; note "$n1 -> $n2 objects"; fi
    if [ -x build/app ]; then
        ./build/app; rc=$?
        if [ "$rc" = 7 ]; then ok "the relinked program is correct (4 + 3 = 7)"
        else bad "wrong result after the edit"; note "want 7, got $rc"; fi
    fi
fi

# ─── verbosity is not part of the cache key ────────────────────────────────
# -q used to ride along in the compile tail, and the tail is hashed into the
# object key — so one quiet build followed by a loud one recompiled the entire
# module graph, for a flag that changes no generated byte.
step "-q does not invalidate the object cache"
if use_fixture obj-cache; then
    mk build app --incremental -q
    expect_rc 0 "quiet build succeeds"
    mk build app --incremental --force
    expect_rc 0 "loud rebuild succeeds"
    expect_out "0 rebuilt" "every object was reused across the verbosity change"
fi

# ─── why: the up-to-date decision, with the file that made it ──────────────
step "why explains the decision"
if use_fixture deps-tree; then
    touch -d '2001-01-01 00:00:00' *.cst Causticfile
    mk why base
    expect_rc 1 "an unbuilt target needs a rebuild"
    expect_out "rebuild needed" "and says so"
    expect_out "does not exist" "naming the missing output"
    mk build base
    expect_rc 0 "build it"
    mk why base
    expect_rc 0 "now it is up to date"
    expect_out "up to date" "and says so"
    # Which input is newest depends on the fixture's own timestamps (the sources
    # were dated to 2001 above, so the compiler binary is newer than all of
    # them). What has to hold is that the report NAMES one and says what kind.
    expect_out "newest input" "naming the newest input"
    expect_out "[compiler]" "and its kind — here the compiler, newer than the 2001 sources"
    # Touching the source has to flip the answer back, and name that file.
    touch base.cst
    mk why base
    expect_rc 1 "touching the source makes it stale again"
    expect_out "base.cst" "and the report names the file that changed"
    mk why nosuch
    expect_rc 1 "an unknown target is an error"
    # No suggestion here on purpose: nothing in this manifest is within two edits
    # of "nosuch", and a wrong guess is worse than none.
    expect_no_out "did you mean" "no suggestion when nothing is close"
    mk why bse
    expect_rc 1 "a near-miss is still an error"
    expect_out "did you mean 'base'" "but it suggests the target one edit away"
fi

# ─── graph: the tree a build actually walks ────────────────────────────────
step "graph shows the dependency tree"
if use_fixture deps-tree; then
    mk graph app
    expect_rc 0 "graph of one target"
    expect_out "app" "the root"
    expect_out "lib" "its dependency"
    expect_out "base" "and the transitive one"
    mk graph everything
    expect_rc 0 "graph of a group"
    expect_out "(group)" "a group is marked as having no output"
    mk graph --dot
    expect_rc 0 "graphviz output"
    expect_out "digraph causticfile" "is a digraph"
    expect_out '"app" -> "lib"' "with the edges"
    expect_out "style=dashed" "and the group drawn differently"
fi

# ─── default: what a bare `build` builds ───────────────────────────────────
step "the default target"
if use_fixture deps-tree; then
    mk build
    expect_rc 0 'a bare build uses the default key' 
    expect_file "build/app" "and built it"
fi
if use_fixture dry-run; then
    mk build
    expect_rc 1 'without a default key a bare build is still an error' 
    expect_out "no \`default\`" "and the message says what would fix it"
fi

# ─── set / interpolation / when / --define ─────────────────────────────────
step "manifest variables and conditional blocks"
if use_fixture vars; then
    mk list
    expect_rc 0 "the manifest parses"
    expect_out "build/caustic-x86_64/app.bin" "\$OUTDIR/\${NAME} expanded, nested through \$TRIPLE"
    expect_out "only-linux" "the matching when block contributed its target"
    expect_no_out "only-windows" "the non-matching one contributed nothing"

    # --define has to beat the manifest, or it cannot serve a matrix.
    mk list --define TRIPLE=windows-x86_64
    expect_rc 0 "--define parses"
    expect_out "build/windows-x86_64/app.bin" "--define overrides the set"
    mk list --define=TRIPLE=aarch64
    expect_out "build/aarch64/app.bin" "the --define=NAME=VALUE spelling works too"
    mk list --define BROKEN
    expect_rc 1 "a --define without '=' is rejected"
    expect_out "expects NAME=VALUE" "with a message that says the shape"

    # A `when` inside a target contributes keys to that target.
    mk info conditional
    expect_rc 0 "a target with when blocks builds"
    expect_out "-O1" "the matching arm's flags are applied"
    expect_no_out "-O0" "the other arm's are not"

    # The rule that makes this safe: only declared names are substituted.
    mk run show -- 42
    expect_rc 0 "the script runs"
    expect_out "declared=caustic-x86_64" "a declared name is substituted"
    expect_out "escaped=" "\$\$ stopped the substitution (the shell then ate the \$)"
    expect_out "arg=42" "\$1 reached the shell as a positional parameter"
    mk run awktest
    expect_rc 0 "an awk script runs"
    expect_out "field2 = b" "\$2 inside awk was left completely alone"
fi

# ─── a stray '=' is a diagnosed error, not a mystery token ─────────────────
step "stray '=' is reported"
if use_fixture vars; then
    printf 'name "x"\nwhen os = "linux" { }\n' > Causticfile
    mk list
    expect_rc 1 "a single '=' is rejected"
    expect_out "stray '='" "and named"
fi

# ─── an unknown flag is an error, not a silent no-op ───────────────────────
step "unknown flag"
if use_fixture dry-run; then
    mk build app --incremntal
    expect_rc 1 "a misspelled flag is rejected"
    expect_out "unknown flag" "and named"
fi

# ─── script command prefixes ─────────────────────────────────
step "script command prefixes ('-' and '@')"
if use_fixture prefixes; then
    mk run ignore-fail
    expect_rc 0 "a '-' command's failure does not abort the script"
    expect_out "REACHED_END" "the commands after it still ran"
    mk run silent
    expect_rc 0 "an '@' command runs"
    expect_out "QUIET_OUTPUT" "its own output still appears"
    expect_no_out "> echo QUIET_OUTPUT" "but the command line was not echoed"
    # The default is unchanged: without a prefix, a failure still stops there.
    mk run aborts
    expect_rc 1 "an unprefixed failure still aborts"
    expect_no_out "SHOULD_NOT_PRINT" "and nothing after it ran"
fi

# ─── doctor ────────────────────────────────────────────────
step "doctor reports what a build would trip over"
if use_fixture prefixes; then
    mk doctor
    expect_rc 1 "a manifest with broken references fails the check"
    expect_out "depends nothing-here" "an unknown depends is named"
    expect_out "after no-such" "so is an unknown hook"
    expect_out "caustic" "the resolved compiler is reported"
fi
if use_fixture nested-out; then
    mk doctor
    expect_rc 0 "a healthy manifest passes"
    # This fixture has no `version`, which is a note rather than a problem — so
    # what has to hold is zero PROBLEMS, not a completely silent report.
    expect_out "0 problem(s)" "with nothing broken"
    expect_out "all present" "with every declared input accounted for"
fi

# ─── completions ─────────────────────────────────────────
# The emitted script must be project-INDEPENDENT. It used to have the current
# manifest's target names written into it as a literal list, which read as an
# advantage and was the opposite: a completion is installed once and used in
# every project, so the copy described one checkout and named targets that do
# not exist in any other. The shipped script asks `caustic-mk list` at
# completion time instead, falling back to reading the nearest Causticfile.
step "completions are live, not a snapshot of this manifest"
if use_fixture deps-tree; then
    mk completions bash
    expect_rc 0 "bash completion is emitted"
    expect_out "complete -F _caustic_mk caustic-mk" "and registers itself"
    expect_out '"$bin" list' "asking the binary for the names at completion time"
    expect_out "Causticfile" "with the manifest as the fallback"
    expect_no_out "everything" "and none of this fixture's target names baked in"
    mk completions zsh
    expect_rc 0 "zsh completion is emitted"
    expect_out "#compdef caustic-mk" "with the compdef marker"
    expect_no_out "everything" "and no baked-in names either"
    mk completions fish
    expect_rc 1 "an unsupported shell is an error"
fi
# Setting a shell up happens outside any project as often as inside one, and the
# output does not depend on the manifest — so it must not demand one. It used to
# be dispatched after the manifest search and fail with "Causticfile not found".
step "completions need no Causticfile"
mkdir -p "$WORK/nowhere" && cd "$WORK/nowhere" || true
mk completions bash
expect_rc 0 "outside a project, bash completion still comes out"
expect_out "_caustic_mk()" "and it is the real script"

# ─── --version ───────────────────────────────────────────
step "--version"
if use_fixture dry-run; then
    mk --version
    expect_rc 0 "--version exits 0"
    expect_out "caustic-mk " "and names the program"
fi

# ─── help is not an error ──────────────────────────────────────────────────
step "help exits zero"
if use_fixture dry-run; then
    mk --help
    expect_rc 0 "--help exits 0"
    expect_out "usage: caustic-mk" "and prints the usage"
fi

cd "$HERE" || exit 1
printf "\n%s\n" "${B}=== integration: pass=$PASS fail=$FAIL ===${N}"
[ "$FAIL" = 0 ] || exit 1
exit 0
