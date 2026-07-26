#!/usr/bin/env bash
#
# Computes the next semantic version from Conventional Commits since the last
# release tag, and prints it to stdout (without a leading "v").
#
# Prints NO_RELEASE when nothing release-worthy has landed, so the caller can
# skip cleanly rather than cutting an empty release.
#
# Usage:
#   scripts/next-version.sh [auto|patch|minor|major]
#
# Bump rules:
#   BREAKING CHANGE in a body, or a "!" before the colon  -> major
#   feat:                                                 -> minor
#   anything else that isn't purely housekeeping           -> patch
#
# Commits whose type is docs/chore/ci/style/test only are treated as
# housekeeping: on their own they do not trigger a release. Commits that don't
# follow the convention at all count as patch-worthy, so an imperfect history
# still releases rather than silently never shipping.

set -euo pipefail

force="${1:-auto}"

case "$force" in
    auto | patch | minor | major) ;;
    *)
        echo "usage: $0 [auto|patch|minor|major]" >&2
        exit 2
        ;;
esac

last_tag="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n1 || true)"

if [[ -z "$last_tag" ]]; then
    range=""
    current="0.0.0"
    had_previous_release="false"
else
    range="${last_tag}..HEAD"
    current="${last_tag#v}"
    had_previous_release="true"
fi

if [[ -n "$range" ]]; then
    count="$(git rev-list --count "$range")"
    subjects="$(git log --format='%s' "$range")"
    bodies="$(git log --format='%b' "$range")"
else
    count="$(git rev-list --count HEAD)"
    subjects="$(git log --format='%s')"
    bodies="$(git log --format='%b')"
fi

if [[ "$count" -eq 0 ]]; then
    echo "NO_RELEASE"
    exit 0
fi

# An explicit opt-out wins, but only where it is unambiguously deliberate:
# in a subject line, or alone on its own line in a body. Matching it anywhere
# in a body means a commit that merely *describes* the marker — release notes,
# documentation, this script's own history — silently suppresses the release.
#
# Read from the tip commit only, because the marker says "*this push* should not
# cut a release" — not "nothing may ever be released again." Scanning the whole
# range made a single deferred commit suppress every automatic release until
# somebody forced one by hand, which is not a thing anyone would think they were
# asking for. Once a later commit lands without the marker the release goes out
# and carries the deferred work with it, still counted in the bump.
#
# Only consulted for automatic runs: a caller who asked for a specific bump has
# said so out loud, and that outranks any marker.
skip_marker='\[skip release\]'
if [[ "$force" == "auto" ]]; then
    head_subject="$(git log -1 --format='%s')"
    head_body="$(git log -1 --format='%b')"
    if grep -qiE "$skip_marker" <<< "$head_subject" \
        || grep -qiE "^[[:space:]]*${skip_marker}[[:space:]]*$" <<< "$head_body"; then
        echo "NO_RELEASE"
        exit 0
    fi
fi

# Conventional Commit type prefix, e.g. "feat(core)!: ..." -> captures "feat".
type_re='^[a-zA-Z]+(\([^)]*\))?!?:'
breaking_re='^[a-zA-Z]+(\([^)]*\))?!:'
housekeeping_re='^(docs|chore|ci|style|test|build)(\([^)]*\))?!?:'

bump="none"

# Per the Conventional Commits spec a breaking change is declared either by "!"
# before the colon, or by a BREAKING CHANGE *footer* — start of line, colon
# required. Matching the phrase anywhere in a body would let a commit that
# merely discusses breaking changes trigger a major bump.
breaking_footer_re='^BREAKING[ -]CHANGE:'

if grep -qE "$breaking_re" <<< "$subjects" \
    || grep -qE "$breaking_footer_re" <<< "$bodies"; then
    bump="major"
elif grep -qE '^feat(\([^)]*\))?:' <<< "$subjects"; then
    bump="minor"
else
    # Patch if at least one commit is either non-conventional or a
    # non-housekeeping type.
    while IFS= read -r subject; do
        [[ -z "$subject" ]] && continue
        if ! grep -qE "$type_re" <<< "$subject"; then
            bump="patch" # not conventional at all -> assume it matters
            break
        fi
        if ! grep -qEi "$housekeeping_re" <<< "$subject"; then
            bump="patch"
            break
        fi
    done <<< "$subjects"
fi

if [[ "$force" != "auto" ]]; then
    bump="$force"
fi

if [[ "$bump" == "none" ]]; then
    echo "NO_RELEASE"
    exit 0
fi

IFS='.' read -r major minor patch <<< "$current"

case "$bump" in
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    patch)
        patch=$((patch + 1))
        ;;
esac

# First ever release starts at 0.1.0 rather than 0.0.1 — a patch bump onto
# nothing reads as though a 0.0.0 once existed.
if [[ "$had_previous_release" == "false" && "$bump" == "patch" ]]; then
    major=0
    minor=1
    patch=0
fi

echo "${major}.${minor}.${patch}"
