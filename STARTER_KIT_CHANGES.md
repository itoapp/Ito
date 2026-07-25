# Hybrid-flow revision

This revision replaces the original pure trunk-based release policy with:

- protected `main` for normal integration;
- temporary `release/X.Y.Z` and `hotfix/X.Y.Z` branches;
- scheduled nightly releases from `main`;
- beta and RC tags from release branches;
- stable tags only after release changes are merged into `main`;
- separate `apps-nightly.json`, `apps-beta.json`, and `apps.json` feeds;
- automatic retention of the newest 14 nightly releases;
- numeric iOS `MARKETING_VERSION` separated from prerelease artifact labels;
- corrected `actions/upload-artifact` usage.
- retained iOS 15.4 support by pinning a custom WasmKit fork.
