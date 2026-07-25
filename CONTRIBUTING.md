# Contributing to Ito

Ito uses a hybrid release flow: protected `main` for normal integration, temporary release and hotfix branches for stabilization, and explicit tags for beta, release-candidate, and stable binaries.

## Local setup

The Xcode project currently references `../ito-runner` as a local Swift package, so clone both repositories as siblings:

```bash
mkdir ito-workspace && cd ito-workspace
git clone https://github.com/itoapp/Ito.git
git clone https://github.com/itoapp/ito-runner.git
open Ito/Ito.xcodeproj
```

A paid Apple Developer Program membership is not required for simulator development or the unsigned CI builds.

## Branches

Create short-lived branches from current `main`:

- `feat/<brief-name>` for user-facing work
- `fix/<brief-name>` for ordinary bug fixes
- `refactor/<brief-name>` for internal restructuring
- `chore/<brief-name>` for maintenance
- `docs/<brief-name>` for documentation

For release work:

- `release/X.Y.Z` is cut from `main` when that version becomes feature-complete.
- `hotfix/X.Y.Z` is cut from the last stable tag when an urgent released-version fix is needed.
- No permanent `develop` branch is used.

Release and hotfix branches accept stabilization work only: bug fixes, version metadata, release notes, localization corrections, and store/distribution preparation. New features continue on `main`.

## Pull requests

1. Keep each pull request focused and reviewable.
2. Include screenshots or a recording for meaningful UI changes.
3. Let GitHub Actions pass before merge.
4. Use squash merge for normal feature and fix pull requests.
5. Merge release/hotfix work back into `main` before creating a stable tag.

Use a Conventional Commit-style pull-request title, such as:

- `feat: add account switching`
- `fix: prevent duplicate timeline requests`
- `release: prepare 1.3.0`
- `hotfix: repair startup migration in 1.3.1`

## Testing without signing

CI builds and tests with code signing disabled. Locally, select an iOS Simulator and run the `Ito` scheme. Do not commit signing identities, `.p12` files, provisioning profiles, Apple account details, or personal development-team identifiers.

## Build channels

- **Nightly:** scheduled from current `main`; intended for early testing.
- **Beta/RC:** tags such as `v1.3.0-beta.1` or `v1.3.0-rc.1`, normally created from `release/1.3.0`.
- **Stable:** tags such as `v1.3.0`, created only from a commit already contained in `main`.

All current unsigned channels use the same bundle identifier, so installing one replaces another. Side-by-side channel installs require separate Xcode configurations, bundle identifiers, and entitlement review.

See `docs/BRANCHING_AND_CHANNELS.md` and `docs/RELEASING.md`.
