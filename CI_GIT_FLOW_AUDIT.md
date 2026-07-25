# Ito CI and release-flow audit

## Executive finding

The repository needs both reliable integration and explicit binary channels. The recommended model is a hybrid release flow: protected `main`, short-lived feature/fix branches, temporary `release/X.Y.Z` and `hotfix/X.Y.Z` branches, scheduled nightlies, prerelease tags, and immutable stable tags.

This preserves simple day-to-day development while supporting release stabilization, beta testing, and a future App Store process without introducing a permanent `develop` branch.

## Repository-specific blockers

### 1. The build is not self-contained

`Ito.xcodeproj` references a local Swift package at `../ito-runner`. A standard CI checkout of only `itoapp/Ito` will fail to resolve that package. The included workflows check out `itoapp/ito-runner` beside Ito at the revision stored in `.github/ito-runner.ref`.

Longer term, replace the local reference with a remote Swift package dependency pinned to a release tag or immutable commit.

### 2. Signing settings are personal

The project file contains a hard-coded Apple development team and automatic-signing settings. CI overrides signing values and sets `CODE_SIGNING_ALLOWED=NO`, but personal team identifiers should still be removed from committed project settings.

### 3. Deployment targets disagree

The app target uses iOS 15.4, while project/test settings include iOS 26.2. Align test targets with the supported minimum unless the newer target is intentional and documented.

### 4. A dependency tracks a moving branch

GRDB is configured from its moving `master` branch. Pin it to a reviewed release range or immutable revision and commit `Package.resolved`.

### 5. User-specific Xcode data is committed

Remove committed `xcuserdata` and ignore generated Xcode state:

```gitignore
xcuserdata/
*.xcuserstate
DerivedData/
build/
*.xcarchive
*.ipa
*.xcresult
```

## Recommended branch model

### Permanent branch

- `main`: next integrated version, protected and buildable.

### Short-lived branches

- `feat/*`, `fix/*`, `refactor/*`, `chore/*`, `docs/*`.

### Temporary release branches

- `release/X.Y.Z`: stabilization and beta/RC preparation.
- `hotfix/X.Y.Z`: urgent fix based on the last stable release.

### Tags

- `vX.Y.Z-beta.N`: beta prerelease.
- `vX.Y.Z-rc.N`: release candidate.
- `vX.Y.Z`: stable release; must be contained in `main`.
- `nightly-YYYYMMDD-RUN`: temporary automated nightly tag.

## Repository rulesets

### `main`

1. require pull requests;
2. require the `Build and unit test` status check;
3. require conversation resolution;
4. require linear history;
5. block force pushes and deletion;
6. allow squash merge;
7. keep approval count at zero for a solo maintainer or one-plus for a team.

### `release/*` and `hotfix/*`

1. require CI before merge;
2. block force pushes and deletion;
3. require pull requests when multiple maintainers are active;
4. allow only stabilization work.

### `v*` tags

Block tag updates and deletion. Do not include `nightly-*` in this immutable-tag rule because the nightly workflow intentionally prunes old tags.

## CI and publication stages

### Pull requests and protected branches

- resolve Swift packages;
- build the app for an iOS Simulator with signing disabled;
- select an installed iPhone simulator dynamically;
- run `ItoTests`;
- upload logs and `.xcresult` on failure.

### Nightly

- scheduled from current `main`;
- run release-configuration tests;
- build an unsigned IPA;
- create a GitHub prerelease;
- update `apps-nightly.json`;
- retain the newest 14 nightly releases.

### Beta and RC

- trigger on explicit `vX.Y.Z-beta.N` and `vX.Y.Z-rc.N` tags;
- allow tags contained in `main`, `release/*`, or `hotfix/*`;
- create a GitHub prerelease;
- update `apps-beta.json`.

### Stable

- trigger on `vX.Y.Z`;
- require the tagged commit to be contained in `main`;
- create a full GitHub Release;
- update `apps.json`.

## Versioning detail

The iOS app's internal `MARKETING_VERSION` remains numeric (`X.Y.Z`). Beta, RC, and nightly labels are used only in artifact filenames, release titles, and source metadata. Build numbers use GitHub's numeric run number.

## Distribution matrix

| Channel | Artifact trust/signing | Source | Status |
|---|---|---|---|
| Nightly | User-side signing or compatible device trust | `apps-nightly.json` | Automated |
| Beta/RC | User-side signing or compatible device trust | `apps-beta.json` | Tagged prerelease |
| Stable | User-side signing or compatible device trust | `apps.json` | Tagged release |
| TestFlight/App Store | Apple distribution signing | Separate future workflow | Deferred |

## Adoption order

1. Merge CI and make it green on `main`.
2. Remove personal signing values and align deployment targets.
3. Pin GRDB and the runner dependency reproducibly.
4. Enable branch and tag rulesets.
5. Run the nightly workflow manually and install-test its IPA.
6. Cut `release/0.x.y`, publish a beta tag, then merge and publish a stable tag.
7. Add App Store/TestFlight signing later as a separate workflow from the same stable tags.
