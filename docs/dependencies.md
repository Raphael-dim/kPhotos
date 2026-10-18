# Dependency review

Reviewed on 2026-10-18. Versions and revisions are locked in [Tuist/Package.resolved](../Tuist/Package.resolved).

| Runtime dependency | Resolved version | License |
| --- | --- | --- |
| Alamofire | 5.12.2 | MIT |
| Realm Swift | 20.0.6 | Apache-2.0 |
| Realm Core (transitive) | 20.1.5 | Apache-2.0, with bundled third-party notices |

These licenses are compatible with GPL-3.0 distribution; preserve upstream license and attribution files when distributing binaries.
[NOTICE](../NOTICE) identifies the runtime libraries; upstream Realm Core includes further third-party notices.
The app currently has no Sentry, Matomo, InfomaniakDI package, ios-core-ui or ZIP dependency.
Development tools are pinned in `.mise.toml`; they are not linked into the app.

## Findings and limits

No published advisories were listed on the upstream security pages checked for
[Alamofire](https://github.com/Alamofire/Alamofire/security/advisories),
[Realm Swift](https://github.com/realm/realm-swift/security/advisories) or
[Realm Core](https://github.com/realm/realm-core/security/advisories).
This is a point-in-time check, not proof that the packages have no vulnerabilities or that every bundled component was audited.

Realm is the main maintenance risk. [Realm Swift 20.0.5](https://github.com/realm/realm-swift/releases/tag/v20.0.5)
introduced Xcode 27 compilation fixes and Realm Core 20.1.5;
[20.0.6](https://github.com/realm/realm-swift/releases/tag/v20.0.6) fixes warnings and packaging.
The upstream C++ fix replaces our former comparator patch. `scripts/prepare_realm.py` now only raises the resource
bundle's manifest deployment target from iOS 12 to 16.6; it leaves upstream C++ intact and rejects an unknown target.
`make check-realm` covers source preservation, repeat runs and that failure boundary, and also runs with lint in CI.

[Alamofire 5.12.1](https://github.com/Alamofire/Alamofire/releases/tag/5.12.1) removes privacy-impacting uptime API usage
and raises its minimum iOS version to 15, within kPhotos' iOS 16.6 minimum;
[5.12.2](https://github.com/Alamofire/Alamofire/releases/tag/5.12.2) only updates versioning.

## Ongoing checks

- Commit the app's lockfile and inspect version/revision changes; review upstream release notes and advisories.
- Dependabot watches SwiftPM and GitHub Actions weekly. Updates still require review and device/database validation.
- Build CI uses GitHub’s `xcode-27` image because the source uses the iOS 27 SDK; runner availability remains an external dependency.
- CI actions use immutable commit SHAs, read-only repository permissions and no persisted checkout credentials.
- Gitleaks scans publishable files and history; inspect images and other binary assets manually as well.
- Private scripts and design references without documented redistribution rights stay under ignored `.local/`.
