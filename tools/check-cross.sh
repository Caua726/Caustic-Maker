#!/usr/bin/env bash
#
# tools/check-cross.sh — OPT-IN cross-target check: the Windows caustic-mk.
#
# Deliberately kept out of the pre-commit gate. It needs wine, which is not on
# every machine, and a commit gate has to give the same verdict everywhere. Run
# it by hand before a release, or whenever the Windows code paths change.
#
# Why it matters more here than in most repos: several of the maker's helpers
# have a Windows branch that nothing on a Linux host ever executes — path
# handling (drive letters, backslashes), `rmdir /s /q` instead of `rm -rf`,
# `cmd.exe /c` instead of `/bin/sh -c`, `NUL` instead of `/dev/null`. Those
# branches were wrong for years without anyone noticing, because no test ran
# them.
#
# Behaviour: wine missing = SKIP (exit 0). wine present and the Windows binary
# broken = FAIL (exit 1).
#
# Usage:  tools/check-cross.sh

set -u
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else B=; G=; R=; Y=; D=; N=; fi
step() { printf "\n%s\n" "${B}▸ $*${N}"; }
ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
skip() { printf "  ${Y}∼ skip${N} %s\n" "$*"; }
bad()  { printf "  ${R}✗${N} %s\n" "$*"; FAILED=1; }
note() { printf "      ${D}%s${N}\n" "$*"; }

PARENT="$(cd "$ROOT/.." && pwd)"
CC=""
for c in "$PARENT/caustic" "$ROOT/caustic"; do [ -x "$c" ] && { CC="$c"; break; }; done
[ -n "$CC" ] || CC="$(command -v caustic 2>/dev/null || true)"
[ -n "$CC" ] || { echo "${R}no caustic compiler found${N}"; exit 1; }

FAILED=0
W="$(mktemp -d "${TMPDIR:-/tmp}/caustic-mk-cross.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

echo "${B}caustic-mk cross-target checks${N} ${D}(opt-in; never gates a commit)${N}"
note "compiler: $CC"

# ─── it has to cross-compile at all ────────────────────────────────────────
step "cross-compile for windows-x86_64"
if "$CC" -q --target=windows-x86_64 "$ROOT/main.cst" -o "$W/caustic-mk.exe" >"$W/build.log" 2>&1; then
    ok "caustic-mk.exe built  $(stat -c%s "$W/caustic-mk.exe" 2>/dev/null || echo '?') bytes"
else
    tail -15 "$W/build.log"
    bad "the Windows build failed"
    printf "\n${R}${B}cross checks FAILED${N}\n"
    exit 1
fi

# ─── and then actually run ─────────────────────────────────────────────────
if ! command -v wine >/dev/null 2>&1; then
    step "run under wine"
    skip "wine is not installed — the .exe was built but not executed"
    printf "\n${G}build-only OK${N} ${D}(install wine to exercise the Windows code paths)${N}\n"
    exit 0
fi

# Quiet wine down; its own chatter drowns the maker's output.
export WINEDEBUG="${WINEDEBUG:--all}"
MK="wine $W/caustic-mk.exe"

# A scratch project, because the point is the maker's Windows behaviour, not
# whether it can find this repo's own sources through wine's path mapping.
PROJ="$W/proj"
mkdir -p "$PROJ"
cat > "$PROJ/Causticfile" <<'EOF'
name "crosstest"
version "0.0.1"

target "app" {
    src "main.cst"
    out "build/app"
}

script "hello" { "echo CROSS_OK" }
EOF
printf 'fn main() as i32 { return 42; }\n' > "$PROJ/main.cst"

run_mk() { OUT="$(cd "$PROJ" && $MK "$@" 2>&1)"; RC=$?; }

step "list / --help under wine"
run_mk --help
case "$OUT" in *"usage: caustic-mk"*) ok "--help prints the usage" ;;
                *) bad "--help output is wrong"; note "$(printf '%s' "$OUT" | head -3)" ;; esac
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC"

run_mk list
case "$OUT" in *"crosstest"*) ok "list reads the Causticfile" ;;
                *) bad "list did not report the project"; note "$(printf '%s' "$OUT" | head -3)" ;; esac

step "info (dry run) under wine"
run_mk info app
case "$OUT" in *"[dry]"*) ok "info prints the command sequence" ;;
                *) bad "info produced no commands"; note "$(printf '%s' "$OUT" | head -5)" ;; esac

step "script through cmd.exe"
run_mk run hello
case "$OUT" in *CROSS_OK*) ok "a script command runs via cmd.exe" ;;
                *) bad "the script did not run"; note "$(printf '%s' "$OUT" | head -5)" ;; esac

# ─── the glob diagnostic ───────────────────────────────────────────────────
# std/io.list_dir has no Windows backend, so a glob CANNOT work there. What it
# must not do is claim the pattern matched nothing — that sends you looking at
# your own directory instead of at the missing capability.
step "glob reports a capability gap, not a wrong answer"
cat > "$PROJ/Causticfile" <<'EOF'
name "crosstest"

target "app" {
    src "main.cst"
    out "build/app"
    source "mods/*.cst"
}
EOF
mkdir -p "$PROJ/mods"
printf 'fn m() as i32 { return 1; }\n' > "$PROJ/mods/one.cst"
run_mk list
if [ "$RC" = 0 ]; then
    skip "globs resolved on this host — nothing to report"
else
    case "$OUT" in
        *"matched nothing"*)
            bad "a glob failure is reported as 'matched nothing'"
            note "the directory is right there; the message points at the wrong thing"
            note "$(printf '%s' "$OUT" | head -3)" ;;
        *)
            ok "the failure is not reported as 'matched nothing'"
            note "$(printf '%s' "$OUT" | grep -i -m1 'error' || true)" ;;
    esac
fi

printf "\n"
if [ "$FAILED" = 0 ]; then
    printf "${G}${B}cross checks OK${N} — the Windows binary builds and runs under wine.\n"
    exit 0
fi
printf "${R}${B}cross checks FAILED${N}\n"
exit 1
