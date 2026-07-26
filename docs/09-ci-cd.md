# 09 · CI/CD, Versioning & Releases

*What runs automatically, how versions are decided, and why signing stays off GitHub.*

## The short version

- **Every push** builds and tests on Linux *and* macOS, and fails on any new compiler warning.
- **Every push to the release branch** computes the next semantic version from commit messages, tags it, and publishes a GitHub Release with generated notes — or skips cleanly when nothing release-worthy landed.
- **Nothing is ever released from a red build.**
- **No signing material is stored in GitHub.** IPAs are published unsigned; Feather signs on-device with your certificate.

## Branching

**Everything lands on `main`.** There is no feature-branch flow: pushes go
straight to `main`, and `main` is what the release workflow watches. CI still
runs on any branch that happens to exist, so a throwaway branch is never
*wrong* — it just isn't the normal path, and nothing releases from one.

## Workflows

### `ci.yml` — on every push and PR

| Job | Runner | What it checks |
|---|---|---|
| `linux` | `swift:6.0.3` container | `swift build` + `swift test`, then a second build with `-warnings-as-errors` |
| `macos` | `macos-15` | Same build/test/warning gate under the Apple toolchain — the real target platform family |
| `app` | `macos-15` | `xcodegen generate` + `xcodebuild` for the iOS app target |
| `scripts` | `ubuntu-latest` | `shellcheck` on the release scripts, and a smoke test that the version logic still produces a valid answer |

The warnings-as-errors step exists because `KoboldCore` builds clean today and that's worth keeping.

**It runs on both platforms deliberately.** `KoboldBLE` is entirely inside `#if canImport(CoreBluetooth)`, so on Linux the gate inspects an empty module and reports success — which is how a genuine concurrency warning in the transport survived several green builds. Any target that is platform-conditional is only really checked by the runner that can compile it. The `app` job exists for the same reason one level up: SwiftUI code compiles nowhere else, and a compile error there should surface on an ordinary push rather than at release time when it blocks shipping.

The `scripts` job exists so a broken release script is caught on an ordinary push, not at the moment you actually need to ship.

### `release.yml` — on push to the release branch, or manually

1. **`verify`** — re-runs the test suite. A release must never be cut from an unverified tree, so this gate is repeated rather than inferred from CI.
2. **`publish`** — computes the version, generates notes, updates `CHANGELOG.md`, creates the tag and GitHub Release.
3. **`detect-app` / `ipa`** — dormant. See [Shipping the app](#shipping-the-app) below.

Manual runs (`workflow_dispatch`) accept a **`bump`** override (`auto`/`patch`/`minor`/`major`) and a **`dry_run`** flag that computes and prints the version without publishing anything.

## Versioning

Versions come from [Conventional Commits](https://www.conventionalcommits.org/). The logic lives in `scripts/next-version.sh` — a script rather than inline YAML specifically so it can be tested locally:

```bash
scripts/next-version.sh          # what would ship right now
scripts/next-version.sh minor    # force a bump
scripts/release-notes.sh 1.2.0   # preview the notes
```

| Commit | Bump |
|---|---|
| `feat!: …` or `BREAKING CHANGE:` in the body | **major** |
| `feat: …` | **minor** |
| `fix:`, `perf:`, `refactor:`, or anything non-conventional | **patch** |
| only `docs:`/`chore:`/`ci:`/`style:`/`test:`/`build:` | **no release** |
| `[skip release]` in the **tip** commit's subject, or alone on a body line | **no release** |

Three deliberate choices:

- **Non-conventional commits count as patch-worthy.** A repo with imperfect commit history should still ship; silently never releasing is a worse failure than a slightly wrong bump.
- **The first release starts at `0.1.0`**, not `0.0.1` — a patch bump onto nothing implies a `0.0.0` that never existed.
- **`[skip release]` defers one push, not the branch.** It is read from the tip commit only. An earlier implementation scanned every commit back to the last tag, which meant one deferred commit silently suppressed *every* automatic release until a human forced one by hand — not something anyone would think they were asking for. Once a later commit lands without the marker, the release goes out and carries the deferred work with it, still counted in the bump: a deferred `fix:` produces a patch even when the commit that unblocks it is housekeeping that would have released nothing on its own.

Both marker forms are matched only where they are unambiguously deliberate — in a subject line, or alone on their own line in a body. Matching anywhere in a body would let a commit that merely *describes* the marker (release notes, this very document) suppress a release. The same applies to `BREAKING CHANGE:`, which must be line-anchored with a colon.

Housekeeping-only pushes produce no release, so documentation and CI tweaks don't churn out versions.

## Shipping the app

The `ipa` job is written and wired but **inert until an iOS app target exists** — `detect-app` looks for an `.xcodeproj`/`.xcworkspace` and skips the build when there isn't one. Once an app target lands it activates with no further changes, and will:

1. Archive with `CODE_SIGNING_ALLOWED=NO`, stamping `MARKETING_VERSION` from the computed version and `CURRENT_PROJECT_VERSION` from the run number.
2. Package the `.app` into an **unsigned** `.ipa`.
3. Attach it to the GitHub Release.

### Why unsigned

Distribution is via Feather using **your own certificate**, and Feather signs on-device. So CI never needs a signing identity, a provisioning profile, or a `.p12`. That is not a workaround — it is strictly better than signing in CI:

- No long-lived Apple credentials in GitHub secrets, so nothing to leak or rotate.
- No annual CI breakage when the certificate rolls over.
- The artifact is identical regardless of which certificate eventually signs it.

> **Caveat:** the `ipa` job's `xcodebuild` invocation has not been executed, because there is no app target to run it against yet. Treat it as a considered starting point rather than a verified one, and expect to adjust the scheme/path details on first real run.

### The Feather source

Add this URL as a source in Feather:

```
https://raw.githubusercontent.com/nphil/kobold/main/source.json
```

It is an AltStore-compatible manifest, so it works in Feather, AltStore and SideStore alike. Add it once and every future release appears as an update instead of a hand-downloaded IPA.

**It is live now but lists no app yet**, because there is no app target to build an IPA from. That is deliberate rather than an oversight: the URL becomes permanent the moment it is added to Feather, so it needs to exist and stay stable from the start. Subscribing today is harmless — the app appears by itself with the first release that ships an IPA.

The manifest is regenerated by the `source` job on every release, straight from the GitHub releases API, and committed back to `main`. Only releases carrying an `.ipa` asset become versions, so Feather is never shown an update it cannot download. Versions sort numerically, not lexically — `0.10.0` correctly outranks `0.2.0`.

The generator is `scripts/build-source.py`, which reads the releases API payload on stdin so it can be tested without CI:

```bash
gh api "repos/nphil/kobold/releases?per_page=100" | python3 scripts/build-source.py
```

## Commit convention

Not enforced by a hook — the version logic degrades gracefully — but following it produces meaningful versions and readable notes:

```
feat(gauges): add tachometer needle physics
fix(elm327): buffer replies that arrive before their waiter
refactor(transport)!: make makeInboundStream async

BREAKING CHANGE: OBDTransport conformers must now await stream creation.
```

Scopes used so far: `transport`, `elm327`, `profile`, `signals`, `adapter`, `ci`, `docs`.

## Cost note

The `macos` CI job runs on every push. GitHub bills macOS runner minutes at 10× the Linux rate, so on a private repo with a limited allowance you may want to restrict it to pull requests and release-branch pushes:

```yaml
  macos:
    if: github.event_name == 'pull_request' || github.ref == 'refs/heads/main'
```

Left running on every push for now, since the Apple toolchain is the one that actually matters for this project and the package is small enough to build in seconds.
