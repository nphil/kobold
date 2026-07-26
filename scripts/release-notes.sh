#!/usr/bin/env bash
#
# Emits Markdown release notes for the commits since the last release tag,
# grouped by Conventional Commit type. Commits that don't follow the convention
# are still listed under "Other changes" rather than being dropped — an
# unreleased change hidden from the notes is worse than an untidy heading.
#
# Usage:
#   scripts/release-notes.sh <version>

set -euo pipefail

version="${1:?usage: $0 <version>}"

last_tag="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n1 || true)"
if [[ -z "$last_tag" ]]; then
    range=""
    compare_note=""
else
    range="${last_tag}..HEAD"
    compare_note="$last_tag"
fi

log() {
    if [[ -n "$range" ]]; then
        git log --format="%H%x1f%s%x1f%b%x1e" "$range"
    else
        git log --format="%H%x1f%s%x1f%b%x1e"
    fi
}

# Prints "- subject (short-sha)" for commits whose subject matches $1.
section() {
    local heading="$1" pattern="$2" found=0 out=""

    while IFS=$'\x1f' read -r -d $'\x1e' sha subject _body; do
        sha="${sha//[$'\n\r']/}"
        [[ -z "$subject" ]] && continue
        if grep -qE "$pattern" <<< "$subject"; then
            # Strip the type prefix so the notes read as prose.
            local text="${subject}"
            text="$(sed -E 's/^[a-zA-Z]+(\([^)]*\))?!?: *//' <<< "$text")"
            out+="- ${text} (\`${sha:0:7}\`)"$'\n'
            found=1
        fi
    done < <(log)

    if [[ "$found" -eq 1 ]]; then
        printf '### %s\n\n%s\n' "$heading" "$out"
    fi
}

# Anything that matched an earlier section must not reappear in "Other".
known_re='^(feat|fix|perf|refactor|docs|test|ci|build|chore|style)(\([^)]*\))?!?:'

echo "## v${version}"
echo

# Breaking changes first: they are the reason someone reads release notes.
breaking=""
while IFS=$'\x1f' read -r -d $'\x1e' sha subject body; do
    sha="${sha//[$'\n\r']/}"
    [[ -z "$subject" ]] && continue
    if grep -qE '^[a-zA-Z]+(\([^)]*\))?!:' <<< "$subject" || grep -q 'BREAKING CHANGE' <<< "$body"; then
        text="$(sed -E 's/^[a-zA-Z]+(\([^)]*\))?!?: *//' <<< "$subject")"
        breaking+="- ${text} (\`${sha:0:7}\`)"$'\n'
    fi
done < <(log)

if [[ -n "$breaking" ]]; then
    printf '### ⚠️ Breaking changes\n\n%s\n' "$breaking"
fi

section "Features" '^feat(\([^)]*\))?!?:'
section "Fixes" '^fix(\([^)]*\))?!?:'
section "Performance" '^perf(\([^)]*\))?!?:'
section "Refactoring" '^refactor(\([^)]*\))?!?:'
section "Documentation" '^docs(\([^)]*\))?!?:'
section "Tests" '^test(\([^)]*\))?!?:'
section "Build & CI" '^(ci|build)(\([^)]*\))?!?:'

# Non-conventional commits, so nothing goes unlisted.
other=""
while IFS=$'\x1f' read -r -d $'\x1e' sha subject _body; do
    sha="${sha//[$'\n\r']/}"
    [[ -z "$subject" ]] && continue
    if ! grep -qEi "$known_re" <<< "$subject"; then
        other+="- ${subject} (\`${sha:0:7}\`)"$'\n'
    fi
done < <(log)

if [[ -n "$other" ]]; then
    printf '### Other changes\n\n%s\n' "$other"
fi

if [[ -n "$compare_note" ]]; then
    echo "**Full changelog:** \`${compare_note}...v${version}\`"
fi
