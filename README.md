# kPhotos

An open source iOS client that backs up your photo library to **kDrive** (Infomaniak's cloud storage), and presents it as a date-sorted timeline.

[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Swift 5.10](https://img.shields.io/badge/swift-5.10-orange.svg)](https://swift.org)
[![Platform iOS 16.6+](https://img.shields.io/badge/iOS-16.6%2B-lightgrey.svg)](#requirements)
[![Status alpha](https://img.shields.io/badge/status-alpha-red.svg)](#status)

> ⚠️ This is an independent, community project. It is **not** an official Infomaniak product and is not affiliated with Infomaniak Network SA. It uses the public kDrive HTTP API. See [NOTICE](NOTICE).

---

## What it does

- Authenticates against your kDrive using a Personal Access Token (PAT).
- Uploads photos and videos from your iOS photo library to a dedicated folder in your kDrive.
- Displays the result as a timeline ordered by **capture date** (`PHAsset.creationDate`), not by upload date.
- Groups items into albums backed by kDrive categories.
- Runs incremental syncs in the background when iOS allows.

The app keeps all media in **your** kDrive — kPhotos has no server, no analytics endpoint, no third-party storage.

## Status

Alpha. Internal use only. Not distributed via TestFlight or the App Store.
Expect breaking changes between commits while the project stabilizes.

## Requirements

- macOS 14+ with Xcode 26+
- iOS 16.6+ for the deployment target
- [Mise](https://mise.jdx.dev/) to install pinned tool versions
- A kDrive account with a Personal Access Token (scope `drive`)

## Quick start

```bash
# 1. Install pinned tools (tuist, swiftlint, swiftformat, periphery)
make setup

# 2. Resolve SPM dependencies and generate the Xcode project
make generate

# 3. Open in Xcode
make open
```

Build and run on simulator from Xcode, or:

```bash
make build           # build only
make run-sim         # build + install + launch on the default simulator
```

### Signing

The project reads the Apple Developer Team ID from the environment so the
repository contains no signing identity:

```bash
export KPHOTOS_DEVELOPMENT_TEAM=YOUR_TEAM_ID
make generate
```

For simulator-only work, leave it unset.

## Architecture

```
kPhotos/             Main app target — SwiftUI App, lifecycle, root navigation
kPhotosCore/         Business logic — Realm models, kDrive API, sync engine.
                     No SwiftUI / UIKit imports.
kPhotosCoreUI/       Reusable SwiftUI components (no business logic).
kPhotosFeatures/     Feature modules — Timeline, Albums, Settings, Map, Auth.
                     ViewModels live here.
kPhotosResources/    Assets and localizable strings.
kPhotosTests/        Unit tests (mirror the source layout).
Tuist/               Project definition (Package.swift, helpers).
docs/                kDrive OpenAPI reference and design notes.
scripts/             Empirical API probes (require a PAT).
```

Detailed conventions live in [AGENTS.md](AGENTS.md).

## Authentication

kPhotos currently authenticates with a Personal Access Token created from
[Infomaniak Manager](https://manager.infomaniak.com/v3/profile/api). Use the
generic `drive` scope.

The token is stored in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
OAuth 2 / PKCE is wired but not enabled by default.

## Contributing

Contributions, bug reports, and feedback are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md).

For security issues, please follow [SECURITY.md](SECURITY.md) and do **not** open a public issue.

## License

kPhotos is licensed under the [GNU General Public License v3.0](LICENSE).
See [NOTICE](NOTICE) for third-party attributions and the independence disclaimer.
