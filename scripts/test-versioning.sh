#!/usr/bin/env bash
#
# Regression tests for the release tooling.
#
# Builds throwaway git repositories with known histories and asserts the version
# each one should produce. Runs in CI on every push, because the release scripts
# are only exercised for real at the moment you actually want to ship — which is
# the worst time to discover they are wrong.
#
# Two of these cases are regressions from real bugs: a commit that merely
# *described* the "[skip release]" marker suppressed a release, and one that
# described a BREAKING CHANGE footer triggered a major bump. Both matched prose.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/next-version.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

passed=0
failed=0

# Starts a fresh repository with a v1.0.0 baseline.
fresh() {
    rm -rf "${workdir}/repo"
    mkdir -p "${workdir}/repo"
    cd "${workdir}/repo"
    git init -q .
    git config user.email test@example.com
    git config user.name "Test"
    git commit -q --allow-empty -m "feat: baseline"
}

commit() { git commit -q --allow-empty -m "$1" ${2:+-m "$2"}; }

expect() {
    local label="$1" want="$2" bump="${3:-auto}" got
    got="$("$script" "$bump")"
    if [[ "$got" == "$want" ]]; then
        echo "  ok       $label"
        passed=$((passed + 1))
    else
        echo "  FAILED   $label — expected '$want', got '$got'"
        failed=$((failed + 1))
    fi
}

echo "Release tooling regression tests"

fresh
expect "first release starts at 0.1.0" "0.1.0"

git tag v1.0.0
expect "no new commits produces no release" "NO_RELEASE"

commit "fix: correct a decode"
expect "fix bumps patch" "1.0.1"

commit "feat: add a gauge"
expect "feat bumps minor" "1.1.0"

commit "feat!: drop the old API"
expect "! bumps major" "2.0.0"

fresh && git tag v1.0.0
commit "refactor: rework transport" "BREAKING CHANGE: OBDTransport is now async"
expect "BREAKING CHANGE footer bumps major" "2.0.0"

# Regression: prose describing the markers must not trigger them.
fresh && git tag v1.0.0
commit "docs: document the release flow" \
    "Covers BREAKING CHANGE footers and the [skip release] opt-out."
commit "fix: a genuine fix"
expect "markers quoted as prose are ignored" "1.0.1"

fresh && git tag v1.0.0
commit "docs: tidy"
commit "chore: housekeeping"
commit "ci: cache builds"
expect "housekeeping alone produces no release" "NO_RELEASE"

commit "fix: a genuine fix"
expect "housekeeping plus a fix bumps patch" "1.0.1"

commit "wip: not conventional at all"
expect "non-conventional commits still release" "1.0.1"

fresh && git tag v1.0.0
commit "fix: something [skip release]"
expect "marker in a subject skips" "NO_RELEASE"

fresh && git tag v1.0.0
commit "fix: something" "[skip release]"
expect "marker alone on a body line skips" "NO_RELEASE"

fresh && git tag v1.0.0
commit "fix: small change"
expect "forced major overrides the computed bump" "2.0.0" "major"
expect "forced minor overrides the computed bump" "1.1.0" "minor"

# A deferred commit must not be able to block a release forever: an explicit
# bump is a human saying "ship it now" and outranks a marker left earlier.
fresh && git tag v1.0.0
commit "feat: deferred while CI was red [skip release]"
expect "marker still skips an automatic run" "NO_RELEASE"
expect "explicit bump overrides the marker" "1.1.0" "minor"

# ...and it must not block the *next* push either. The marker defers its own
# commit, not everything after it. Scanning the whole range made one marker
# suppress every automatic release until the next tag.
commit "fix: the thing that was red"
expect "a later commit releases despite an earlier marker" "1.1.0"

# The bump reflects the whole range, not just the tip: a deferred fix still
# produces a patch even though the commit that unblocks it is housekeeping,
# which on its own would have produced nothing.
fresh && git tag v1.0.0
commit "fix: deferred [skip release]"
commit "docs: tidy up"
expect "deferred work counts toward the bump" "1.0.1"

echo
echo "  ${passed} passed, ${failed} failed"
[[ "$failed" -eq 0 ]]
