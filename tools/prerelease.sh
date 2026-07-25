#!/usr/bin/env bash
#
# tools/prerelease.sh — release-readiness check (run BEFORE cutting a release).
#
# The failure this exists to prevent: shipping a binary tagged v0.2.0 whose
# `caustic-mk --version` still says 0.1.1, because the version lives in two
# places and only one got bumped. That had already happened here — the Causticfile
# said 0.1.0 while version.cst and the latest tag said 0.1.1, and nothing in the
# repo could tell you which was right.
#
# Checks:
#   1. version.cst and Causticfile agree on the version string.
#   2. That version is strictly NEWER than the latest release tag.
#   3. The tag v<version> does not already exist.
#   4. version.cst is TRACKED — it is what --version reports, so it cannot be a
#      build artifact that a clean checkout lacks.
#
# It reads only the working tree and git metadata: builds nothing, changes
# nothing. Correctness is tools/precommit.sh's job; this checks bookkeeping.
#
# Usage:  tools/prerelease.sh
# Skip:   PRERELEASE_SKIP=1 tools/prerelease.sh

set -u
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else B=; G=; R=; Y=; D=; N=; fi
step() { printf "%s\n" "${B}▸ $*${N}"; }
ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
info() { printf "      ${D}%s${N}\n" "$*"; }
die()  { printf "  ${R}✗ %s${N}\n" "$1"
         printf "\n${R}${B}pre-release NOT ready${N} — %s\n" "${2:-fix the above before releasing}"
         exit 1; }

if [ "${PRERELEASE_SKIP:-0}" = "1" ]; then echo "${Y}pre-release check skipped (PRERELEASE_SKIP=1)${N}"; exit 0; fi

# ---- the two sources of truth ----------------------------------------------
step "Version bookkeeping"

VER_SRC="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' version.cst 2>/dev/null | head -1 | tr -d '"')"
VER_MK="$(grep -E '^[[:space:]]*version[[:space:]]' Causticfile 2>/dev/null | grep -oE '"[^"]+"' | head -1 | tr -d '"')"

[ -n "$VER_SRC" ] || die "could not read a version from version.cst"
[ -n "$VER_MK" ]  || die "could not read a version from Causticfile"

if [ "$VER_SRC" != "$VER_MK" ]; then
    printf "  ${R}✗${N} version mismatch: version.cst=${B}%s${N} vs Causticfile=${B}%s${N}\n" "$VER_SRC" "$VER_MK"
    die "the two sources disagree" "make version.cst and Causticfile agree"
fi
VER="$VER_SRC"
ok "version.cst and Causticfile agree: ${B}$VER${N}"

# version.cst is what `caustic-mk --version` prints, so it has to exist in a
# fresh clone. It used to be generated (and .gitignore'd), which meant a clean
# checkout had no version at all.
if git ls-files --error-unmatch version.cst >/dev/null 2>&1; then
    ok "version.cst is tracked"
else
    printf "  ${R}✗${N} version.cst is NOT tracked by git\n"
    die "untracked version" "git add version.cst — a clean clone must carry it"
fi

# ---- against the latest tag ------------------------------------------------
# Fetch first: the check compares against the latest RELEASE, and a tag pushed
# from another checkout is invisible to a local `git tag`. Reading a stale list
# once let this script compare 0.2.0 against v0.1.1 while v0.1.2 already existed
# on the remote. A failure to reach the network is not fatal — it just means the
# comparison is against what is known locally, and it says so.
if git fetch --tags --quiet origin 2>/dev/null; then :
else printf "  ${Y}∼${N} could not fetch tags — comparing against local tags only\n"; fi
LAST_TAG="$(git tag --sort=-v:refname 2>/dev/null | grep -E '^v?[0-9]' | head -1)"
if [ -z "$LAST_TAG" ]; then
    ok "no prior tag — this would be the first release (v$VER)"
    LAST_VER=""
else
    LAST_VER="${LAST_TAG#v}"
    info "latest release tag: $LAST_TAG"
fi

if [ -n "$LAST_VER" ]; then
    if [ "$VER" = "$LAST_VER" ]; then
        printf "  ${R}✗${N} version is still ${B}%s${N} — unchanged since %s\n" "$VER" "$LAST_TAG"
        printf "      ${Y}Bump it in both places before releasing:${N}\n"
        printf "        • version.cst  →  let is *u8 as VERSION with imut = \"X.Y.Z\";\n"
        printf "        • Causticfile  →  version \"X.Y.Z\"\n"
        die "not bumped" "you are about to re-release $LAST_TAG"
    fi
    NEWEST="$(printf '%s\n%s\n' "$LAST_VER" "$VER" | sort -V | tail -1)"
    if [ "$NEWEST" != "$VER" ]; then
        printf "  ${R}✗${N} version ${B}%s${N} is OLDER than the last release ${B}%s${N}\n" "$VER" "$LAST_VER"
        die "went backwards" "the new version must be greater than $LAST_TAG"
    fi
    ok "version ${B}$VER${N} is newer than the last release ($LAST_TAG)"
fi

if git rev-parse "v$VER" >/dev/null 2>&1; then
    printf "  ${R}✗${N} tag ${B}v%s${N} already exists\n" "$VER"
    die "tag taken" "delete it or bump to an unused version"
fi
ok "tag ${B}v$VER${N} is free"

# ---- what would ship -------------------------------------------------------
if [ -n "$LAST_TAG" ]; then
    NCOMMITS="$(git rev-list --count "$LAST_TAG"..HEAD 2>/dev/null || echo '?')"
    step "Release scope"
    info "$NCOMMITS commits since $LAST_TAG"
    info "changelog:  git log --oneline $LAST_TAG..HEAD"
    if [ -f CHANGELOG.md ] && ! grep -q "$VER" CHANGELOG.md; then
        printf "  ${Y}∼${N} CHANGELOG.md has no entry for %s yet\n" "$VER"
    fi
fi

printf "\n${G}${B}pre-release ready${N} — version ${B}v$VER${N}.\n"
printf "${D}Release flow:${N}\n"
printf "${D}  1. tools/precommit.sh    — build + self-build fixpoint + both suites${N}\n"
printf "${D}  2. tools/check-cross.sh  — optional: the Windows binary under wine${N}\n"
printf "${D}  3. git tag v$VER && git push origin v$VER${N}\n"
exit 0
