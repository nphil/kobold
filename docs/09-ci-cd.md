# 09 · CI/CD, Versioning & Releases

*What runs automatically, how versions are decided, and why signing stays off GitHub.*

## The short version

- **Every push** builds and tests on Linux *and* macOS, and fails on any new compiler warning.
- **Every push to the release branch** computes the next semantic version from commit messages, tags it, and publishes a GitHub Release with generated notes — or skips cleanly when nothing release-worthy landed.
- **Nothing is ever released from a red build.**
- **No signing material is stored in GitHub.** IPAs are published unsigned; Feather signs on-device with your certificate.

## Workflows

### `ci.yml` — on every push and PR

| Job | Runner | What it checks |
|---|---|---|
| `linux` | `swift:6.0.3` container | `swift build` + `swift test`, then a second build with `-warnings-as-errors` |
| `macos` | `macos-15` | Same build/test under the Apple toolchain — the real target platform family |
| `scripts` | `ubuntu-latest` | `shellcheck` on the release scripts, and a smoke test that the version logic still produces a valid answer |

The warnings-as-errors step exists because `KoboldCore` builds clean today and that's worth keeping. The `scripts` job exists so a broken release script is caught on an ordinary push, not at the moment you actually need to ship.

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
| any commit containing `[skip release]` | **no release** |

Two deliberate choices:

- **Non-conventional commits count as patch-worthy.** A repo with imperfect commit history should still ship; silently never releasing is a worse failure than a slightly wrong bump.
- **The first release starts at `0.1.0`**, not `0.0.1` — a patch bump onto nothing implies a `0.0.0` that never existed.

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

### Feather auto-updates (not yet wired)

Feather can subscribe to an AltStore-compatible source — a JSON manifest listing available versions and download URLs. Publishing one would let you add a single URL to Feather and get update prompts instead of downloading IPAs by hand.

It needs the IPA job live first, plus a hosting decision (GitHub Pages, or a raw file on the default branch). Deferred rather than guessed, since the URL becomes permanent once you've added it to Feather.

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
