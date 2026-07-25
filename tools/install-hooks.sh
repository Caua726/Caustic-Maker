#!/usr/bin/env bash
#
# tools/install-hooks.sh — install this repo's git hooks.
#
# Two things make "just drop a file in .git/hooks" wrong here:
#
#   1. caustic-maker is normally a SUBMODULE. Its .git is a FILE pointing at
#      <parent>/.git/modules/caustic-maker/, and that is where git looks for
#      hooks. A hook written to ./.git/hooks/ does nothing at all, silently —
#      which is the state this repo was in.
#
#   2. A global `core.hooksPath` (git config --global) REPLACES the per-repo
#      hook directory entirely. If one is set, the hook installed below is
#      correct but shadowed, and git will never run it. This script says so and
#      offers a dispatcher instead of quietly writing into a directory shared by
#      every repository on the machine.
#
# Installs (repo-local only, never global unless you ask):
#   pre-commit — runs tools/precommit.sh (build + fixpoint + suites)
#   commit-msg — rejects AI-attribution trailers, per CLAUDE.md
#
# Usage:  tools/install-hooks.sh            install into this repo's hook dir
#         tools/install-hooks.sh --force    overwrite existing hooks
#         tools/install-hooks.sh --status   report what is installed and reachable
#         tools/install-hooks.sh --local    point THIS repo at its own hook
#                                           directory (repo-local config; the
#                                           fix the parent repo uses)
#         tools/install-hooks.sh --dispatch ALSO add a global pre-commit that
#                                           delegates to each repo's own hook
#                                           (touches a shared directory — opt-in)

set -u
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else B=; G=; R=; Y=; D=; N=; fi
ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
warn() { printf "  ${Y}∼${N} %s\n" "$*"; }
note() { printf "      ${D}%s${N}\n" "$*"; }
die()  { printf "  ${R}✗ %s${N}\n" "$*"; exit 1; }

FORCE=0; STATUS=0; DISPATCH=0; LOCAL=0
for a in "$@"; do
    case "$a" in
        --force|-f)   FORCE=1 ;;
        --status|-s)  STATUS=1 ;;
        --local|-l)   LOCAL=1 ;;
        --dispatch)   DISPATCH=1 ;;
        -h|--help)    echo "usage: tools/install-hooks.sh [--force] [--status] [--local] [--dispatch]"; exit 0 ;;
        *) die "unknown argument '$a'" ;;
    esac
done

GITDIR="$(git rev-parse --git-dir 2>/dev/null)" || die "not a git repository"
case "$GITDIR" in /*) ;; *) GITDIR="$ROOT/$GITDIR" ;; esac
HOOKS="$GITDIR/hooks"                       # this repo's own hook directory
GLOBAL="$(git config --get core.hooksPath 2>/dev/null || true)"

printf "%s\n" "${B}caustic-mk git hooks${N}"
note "repo hook directory: $HOOKS"
[ -f "$ROOT/.git" ] && note "(submodule — ./.git/hooks/ is NOT where git looks)"

# Is the repo's own directory the one git will actually use?
REACHABLE=1
if [ -n "$GLOBAL" ]; then
    case "$GLOBAL" in
        "$HOOKS"|"$HOOKS"/) ;;
        *) REACHABLE=0 ;;
    esac
fi

if [ "$STATUS" = 1 ]; then
    for h in pre-commit commit-msg; do
        if [ -x "$HOOKS/$h" ]; then ok "$h installed"; else warn "$h not installed"; fi
    done
    if [ "$REACHABLE" = 0 ]; then
        warn "core.hooksPath = $GLOBAL — the repo's hooks are shadowed"
        if [ -x "$GLOBAL/pre-commit" ] && grep -q 'hooks/pre-commit' "$GLOBAL/pre-commit" 2>/dev/null; then
            ok "the global pre-commit delegates to this repo's hook — it will run"
        else
            warn "no global pre-commit dispatcher — this repo's pre-commit will NOT run"
            note "add one with: tools/install-hooks.sh --dispatch"
        fi
        if [ -x "$GLOBAL/commit-msg" ] && grep -q 'hooks/commit-msg' "$GLOBAL/commit-msg" 2>/dev/null; then
            ok "the global commit-msg delegates to this repo's hook — it will run"
        fi
    fi
    exit 0
fi

mkdir -p "$HOOKS" || die "could not create $HOOKS"

install_hook() {                       # install_hook <name> <body>
    local name="$1" body="$2" path="$HOOKS/$1"
    if [ -e "$path" ] && [ "$FORCE" != 1 ]; then
        warn "$name already exists — left alone (use --force to overwrite)"
        return 0
    fi
    printf '%s' "$body" > "$path" || die "could not write $path"
    chmod +x "$path" || die "could not make $path executable"
    ok "$name installed"
}

# The wrapper is deliberately self-guarding: if it is ever reached from a
# checkout without tools/precommit.sh it exits 0 instead of failing the commit.
install_hook pre-commit '#!/bin/sh
# Thin wrapper (NOT tracked — lives in the git hook directory). The real,
# version-controlled logic is tools/precommit.sh: caustic-mk builds itself, the
# self-build fixpoint holds, all three build paths work, both suites pass.
#   skip:  PRECOMMIT_SKIP=1 git commit ...   or   git commit --no-verify
gate="$(git rev-parse --show-toplevel 2>/dev/null)/tools/precommit.sh"
[ -x "$gate" ] || exit 0
exec "$gate"
'

install_hook commit-msg '#!/bin/sh
# Local guard (NOT tracked). Rejects any commit message carrying Claude/
# Anthropic/AI attribution, per the CLAUDE.md commit policy: no Co-Authored-By
# trailer, no "Generated with", no claude.ai/claude.com link, no robot marker.
# A bare mention of the CLAUDE.md *filename* is fine — that is not attribution.
msg_file="$1"
if grep -qiE "co-authored-by.*(claude|anthropic)|noreply@anthropic|generated with.*claude|claude\.ai/|claude\.com/claude-code|🤖" "$msg_file"; then
    echo "" >&2
    echo "commit-msg: message contains Claude/Anthropic/AI attribution — BLOCKED." >&2
    echo "  CLAUDE.md policy: no Co-Authored-By / \"Generated with\" / AI markers." >&2
    exit 1
fi
exit 0
'

# ---- the shadowing problem -------------------------------------------------
if [ "$REACHABLE" = 0 ]; then
    printf "\n"
    warn "core.hooksPath is set globally to $GLOBAL"
    note "git reads hooks from there, so the hooks just installed are shadowed."

    HAS_DISPATCH=0
    if [ -x "$GLOBAL/pre-commit" ] && grep -q 'hooks/pre-commit' "$GLOBAL/pre-commit" 2>/dev/null; then
        HAS_DISPATCH=1
    fi

    if [ "$HAS_DISPATCH" = 1 ]; then
        ok "a global pre-commit dispatcher is already there — this repo's hook will run"
    elif [ "$DISPATCH" = 1 ]; then
        # Mirrors the delegation the existing global commit-msg already does:
        # run the repo's own hook, then get out of the way. Harmless in repos
        # that have no pre-commit of their own.
        if [ -e "$GLOBAL/pre-commit" ] && [ "$FORCE" != 1 ]; then
            warn "$GLOBAL/pre-commit exists — left alone (use --force to overwrite)"
        else
            mkdir -p "$GLOBAL" || die "could not create $GLOBAL"
            cat > "$GLOBAL/pre-commit" <<'DISPATCHER'
#!/bin/sh
# Global pre-commit dispatcher (core.hooksPath). Runs the repository's own
# pre-commit hook, if it has one, and otherwise does nothing. Mirrors what the
# global commit-msg guard already does for commit messages.
gitdir="$(git rev-parse --git-dir 2>/dev/null)"
if [ -n "$gitdir" ] && [ -x "$gitdir/hooks/pre-commit" ]; then
    exec "$gitdir/hooks/pre-commit" "$@"
fi
exit 0
DISPATCHER
            chmod +x "$GLOBAL/pre-commit" || die "could not make the dispatcher executable"
            ok "global dispatcher installed at $GLOBAL/pre-commit"
            note "it only delegates — repos without a pre-commit are unaffected"
        fi
    elif [ "$LOCAL" = 1 ]; then
        # The least invasive fix, and the one the parent repo already uses: a
        # repo-local core.hooksPath. Nothing outside this repo changes, and
        # nothing is lost — the commit-msg guard was installed here too, so the
        # global one being bypassed for this repo costs nothing.
        if git config --local core.hooksPath "$HOOKS"; then
            ok "core.hooksPath set for this repo -> $HOOKS"
            note "both hooks now run here; undo with: git config --local --unset core.hooksPath"
        else
            die "could not set the repo-local core.hooksPath"
        fi
    else
        printf "      ${D}%s${N}\n" "This repo's pre-commit will NOT run as things stand."
        printf "      ${D}%s${N}\n" "Recommended — repo-local, changes nothing outside this repo:"
        printf "      ${D}%s${N}\n" "    tools/install-hooks.sh --local"
        printf "      ${D}%s${N}\n" "(This is what the parent Caustic repo does. The commit-msg guard is"
        printf "      ${D}%s${N}\n" " installed here too, so nothing is lost by bypassing the global one.)"
        printf "      ${D}%s${N}\n" "Or, to fix every repo at once by writing to the shared directory:"
        printf "      ${D}%s${N}\n" "    tools/install-hooks.sh --dispatch"
        printf "      ${D}%s${N}\n" "Or just run the gate by hand:  tools/precommit.sh"
    fi
fi

printf "\n${G}${B}hooks installed${N} — %s\n" "$HOOKS"
printf "${D}  pre-commit runs tools/precommit.sh; skip once with PRECOMMIT_SKIP=1 or --no-verify.${N}\n"
exit 0
