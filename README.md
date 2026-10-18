# kPhotos

Independent open source iOS client for [kDrive](https://www.infomaniak.com/kdrive), licensed under [GPL-3.0](LICENSE).
Not affiliated with or endorsed by Infomaniak. See [NOTICE](NOTICE).

## Status and features

Alpha, under active development. Expect breaking changes; keep an independent copy of your originals.

- Browse local photos and an existing kDrive folder in a timeline ordered by capture date.
- Back up PhotoKit photos, videos and companion resources, with byte verification.
- Browse albums backed by kDrive categories, view fullscreen media and display available GPS locations.
- Prepare original-media metadata on Wi-Fi and cache it for subsequent visits.
- Group cloud Live Photos only when embedded Apple identifiers establish an unambiguous pair.

Capture dates come from PhotoKit or embedded original metadata. Cloud file dates are explicitly approximate fallbacks.
Background work depends on the time granted by iOS; continuous background sync is not guaranteed.
There is no kPhotos server or analytics service.

## Build

Requires macOS, Xcode with the SDK used by the source (currently Xcode 27), and [Mise](https://mise.jdx.dev/).
The deployment target remains iOS 16.6; newer APIs have availability fallbacks.

```sh
make setup
make generate
make run-sim                 # defaults to iPhone 17
# or: make open
```

For a physical device, set `TUIST_KPHOTOS_DEVELOPMENT_TEAM` locally in the ignored `.mise.local.toml`, then regenerate.
Simulator builds also need ad-hoc signing for Keychain access. The app identifier is `app.kphotos`.
Changing a bundle identifier does not migrate its container or Keychain.

## Connect a library

Create a Personal Access Token in [Infomaniak Manager](https://manager.infomaniak.com/v3/profile/api-token)
with the `drive` scope, then enter it in the app. The token is stored in the iOS Keychain.
OAuth code exists but is inactive and ships without a client identifier.

Select an existing destination folder in Settings. Browsing does not create folders or start uploads.
Gallery indexing reads image/video listings; metadata comes from originals, never Google sidecars or ZIP archives.
An optional app-owned `.kphotos-index` cache on kDrive contains derived metadata, including capture dates and GPS when available.

## Documentation

- [Product goals and boundaries](docs/product-scope.md)
- [Local agent workflow](WORKFLOW.md)
- [Contributing and checks](CONTRIBUTING.md)
- [Development commands](COMMANDS.md)
- [Architecture and media safety](docs/galerie-et-live-photos.md)
- [Infomaniak API reference](docs/api/README.md)
- [Dependency review](docs/dependencies.md)
- [Project rules for agents](AGENTS.md)
- [Changelog](CHANGELOG.md) and [security reporting](SECURITY.md)
