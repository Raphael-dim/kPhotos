# AGENTS.md — kPhotos (iOS)

Read this file end to end before modifying source. These are durable project rules, not a development-session log.
Preserve unrelated working changes. Follow [WORKFLOW.md](WORKFLOW.md) for local validation/commit policy.

## Mission and product boundaries

**kPhotos** is an independent open source iOS client for **kDrive**, dedicated to backing up and organizing photos and videos.
It is not affiliated with Infomaniak Network SA. Follow the useful architectural conventions of the Infomaniak iOS ecosystem
without presenting the project as an official product.

The central guarantee is capture-date ordering: PhotoKit creation dates or original embedded metadata, never upload dates.
Cloud file dates are explicitly approximate fallbacks. Originals must remain intact and recoverable.
The app works with the iPhone and Infomaniak; no additional kPhotos server or Mac worker is required.

The [product scope](docs/product-scope.md) preserves the v1/v2 goals and exclusions.
Treat goals as scope guidance, not proof that a feature exists. Do not add placeholder controls for unfinished actions.

## Active stack and tooling

| Component | Choice / rule |
| --- | --- |
| Language | Swift 5.10 |
| UI / deployment | SwiftUI first; UIKit only when required; iOS 16.6 minimum |
| Build / dependencies | Tuist, SPM; Xcode SDK required by current source (currently Xcode 27) |
| Tool versions | Mise, `.mise.toml` |
| Networking | Alamofire directly; no installed ios-core-ui dependency |
| Database | RealmSwift through `RealmAccessor` |
| DI | Local `@InjectService` / `SimpleResolver` / `Factory` shim compatible with InfomaniakDI |
| Quality | SwiftLint, SwiftFormat, Periphery, Gitleaks |
| Strings | `kPhotosResources`, English and French localizations |
| CI / updates | GitHub Actions, Dependabot |
| Commits / license | Conventional Commits, GPL-3.0 |

`Tuist/Package.swift` declares packages; `Tuist/Package.resolved` records exact versions and revisions.
See [dependency policy and review](docs/dependencies.md). SwiftLint/SwiftFormat are tools, not SPM app dependencies.
Sentry, Matomo, Loco and SonarCloud remain intended ecosystem choices if their integration becomes necessary;
none should be documented as active without its implementation/configuration. Never use Firebase/Google analytics.
Add a package only for a real caller, after reviewing its license, maintenance and security impact.

## Context map and layer boundaries

```text
kPhotos/                         App assembly, lifecycle and root navigation
kPhotosCore/
  Auth/                          PAT, Keychain and inactive OAuth/PKCE support
  DI/                            FactoryService and local DI shim
  Data/Api/                      Endpoint extensions, DTOs, PhotoApiFetcher capabilities
  Data/Models/                   Realm state containers and snapshots
  Data/Database/                 RealmAccessor, encryption and migration
  Data/Cache/                    Photo/album/timeline/settings managers
  Drives/                        Drive discovery and selected-folder access
  Gallery/                       Pure composition, selection and Live Photo pairing
  Photos/                        PhotoKit, original metadata and bounded media/cache transport
  Sync/                          Library scans, metadata preparation, verified backup and scheduling
  Upload/                        Upload queue abstractions
kPhotosCoreUI/                   Reusable UI, gallery loaders, states and theme
kPhotosFeatures/<Feature>/       Views and ViewModels: Auth, Timeline, Albums, Map, Backup, Settings…
kPhotosResources/               Asset catalogues, L10n and *.lproj strings
kPhotosTests/                   Tests mirroring source capabilities
Tuist/                          Package declarations/lockfile and project helpers
Project.swift                   Target definitions
scripts/                        Build checks, API export refresh and manual API probes
```

- `kPhotosCore` never imports SwiftUI or UIKit.
- `kPhotosCoreUI` contains reusable presentation components, not business decisions.
- Views and ViewModels live in `kPhotosFeatures`; ViewModels never live in Core.
- `kPhotos` assembles services and navigation; do not put feature logic there.
- A SwiftUI view reads Realm through `@ObservedResults` or a dedicated ViewModel, never by traversing manager internals.
- Widgets, share extensions and dedicated UI-test targets are product goals, not directories to assume exist.

## Code conventions and design principles

### Style

- `camelCase` for variables/functions, `PascalCase` for types.
- Max line width: **130 characters**.
- Indentation: **4 spaces**, line endings **LF**.
- Imports: grouped alphabetically, blank line after the block.
- SwiftUI: property wrappers **private** (`@State private`, `@StateObject private`, `@ObservedObject private`).
- Every source file starts with the GPL-3.0 header from `file-header-template.txt`.
- No `try!`, `as!` or force unwraps in production code. Represent expected absence and failure explicitly.

### Strings

- **Always** go through the keys in `kPhotosResources`. No user-facing string literal in code.

### Dependency injection (local InfomaniakDI-compatible shim)

```swift
// Registration (kPhotosCore/DI/FactoryService.swift)
FactoryService.store.store(factory: Factory(type: PhotoReading.self) { _, _ in
    PhotoManagerImpl(realm: resolve())
})

// Usage
@InjectService var photoReader: PhotoReading
```

Managers expose focused **protocols** (e.g. `PhotoReading` / `PhotoWriting`), never the concrete class directly.
The registration example belongs inside `FactoryService`; production features consume the registered protocol.

### API layer

- Extend `PhotoApiFetcher` for each capability via focused extensions:
  - `PhotoApiFetcher+Upload.swift`
  - `PhotoApiFetcher+Listing.swift`
  - `PhotoApiFetcher+Albums.swift`
- Endpoints in `Endpoint.swift` + extensions `Endpoint+Photos.swift`, `Endpoint+Albums.swift`.

### Concurrency

- **Always** `async/await` and structured concurrency.
- Never callbacks / completion handlers unless framework interoperability forces it.
- Propagate cancellation through child tasks, transports and queued work; cancellation is not an upload or metadata failure.

### Realm persistence

- Realm models require primary keys. Managed objects are thread-confined; expose value snapshots across boundaries.
- Writes go **through `RealmAccessor`** on a background context.
- No Realm write on the main thread.
- UI reads: `@ObservedResults` or a dedicated ViewModel.

### Manager naming pattern

```
PhotoManager       // photo management
AlbumManager       // album management
TimelineManager    // timeline construction
SyncEngine         // sync engine
UploadQueue        // upload queue
```

### File naming

- Capability extensions: `PhotoApiFetcher+Upload.swift` (`+Capability` pattern).
- Endpoints: `Endpoint+Photos.swift`, `Endpoint+Albums.swift`.
- Features: `Feature` suffix (e.g. `TimelineFeature`).
- ViewModels: `ViewModel` suffix (e.g. `TimelineViewModel`).
- Tests: mirror source + `Tests` suffix.

### Design principles (mandatory)

These principles guide every technical decision. When they conflict, priority order is: **correctness → readability → testability → performance → elegance**.

#### SOLID

- **S — Single Responsibility.** One type, one reason to change.
  - `PhotoManager` manages the photo index. It does **not** upload (→ `UploadQueue`), does not sync (→ `SyncEngine`), does not observe the iOS photo library (→ `PhotoLibraryObserverImpl`).
  - A type exceeding ~300 lines or named "manager utility helper" is a signal to review its responsibilities.
    Existing oversized types are debt to reduce through focused changes, not a reason to weaken lint rules.
- **O — Open / Closed.** Open for extension, closed for modification.
  - Adding a new API capability: create `PhotoApiFetcher+NewCapability.swift`; keep capability logic out of the base file.
    Update protocol declarations and DI when required by a real caller.
  - Adding a media kind: go through an `enum MediaKind` + exhaustive switch (compile-time safety), not scattered `if`s.
- **L — Liskov Substitution.** Every protocol implementation must be substitutable without surprises.
  - A `MockPhotoManager` used in tests **must** respect the same invariants (ordering, async, throws) as `PhotoManagerImpl`.
- **I — Interface Segregation.** Many small protocols rather than one large one.
  - Do not expose a giant `PhotoManager`. Prefer `PhotoReading`, `PhotoWriting`, `PhotoSyncing`. A view that only reads injects `PhotoReading`.
- **D — Dependency Inversion.** Depend on abstractions, never on concrete classes.
  - Features depend on **protocols** resolved via `@InjectService` (InfomaniakDI). Production features do not instantiate `PhotoManagerImpl` directly; registration belongs in `FactoryService`.
    Tests may construct the implementation under test with explicit fake collaborators.

#### KISS — Keep It Simple

- Prefer a long, linear function over a cascade of abstractions you have to guess at.
- No generic or protocol if there is a single implementation **and** no test will mock it. (Unless the protocol is required by the DI architecture above.)
- No design pattern "because it is elegant": prove it avoids a concrete duplication **already present**.

#### DRY — Don't Repeat Yourself (with judgment)

- Factor out when a piece of logic is duplicated in 3+ places. At 2 places, wait (often it is a false duplication).
- "Same shape, different reason" is **not** duplication. Two functions that format a date for independent reasons can stay separate.
- Structural duplication (Realm boilerplate, API → Model mapping) is factored out via extensions and helpers in `kPhotosCore/Data`.

#### YAGNI — You Aren't Gonna Need It

- Do not write an "extensibility hook" or an optional parameter "just in case". Every piece of code must have a real caller **in this commit**.
- No prospective abstraction layers (`PhotoServiceProviderFactoryBuilder`). Add a layer when a second real case appears.
- Tied to `kPhotosCore`: introduce a manager protocol only when it is actually injected somewhere.

#### Composition over inheritance

- No class inheritance for business types. Realm models only inherit from `Object` (framework constraint).
- ViewModels compose injected protocols; they do not inherit from a `BaseViewModel`.

#### Law of Demeter (Tell, don't ask)

- A view does not write `viewModel.photoManager.realm.objects(Photo.self)`. It asks for `viewModel.photos`.
- Avoid chains of more than 2 consecutive accesses across different objects. Expose the needed operation on the intermediate object.

#### Fail fast at the boundaries, never in the middle

- Validation **only at boundaries** (user input, API response, data loaded from the iOS photo system). Past that, trust the types.
- Errors are **typed and local**: `PhotoAPIError`, `UploadError`, `SyncError`.
  Translate framework errors at the boundary; avoid exposing unstructured errors as the domain contract.
- No `try?` to silence an error. If you choose to ignore one, comment the reason (e.g. expected cache miss).

#### Pure functions and immutability

- Any computation logic (timeline grouping, deduplication, sorting) is written as **pure functions** over structs / value types, testable without Realm or networking.
- Realm models are state containers; any derived logic lives outside (extensions or helpers).
- Prefer `let` everywhere. `var` must be justified (short local mutation).

#### Readability over brevity

- Explicit names > abbreviations. `photoIdentifier` rather than `phId`. Exceptions: standard names (`id`, `url`, `db`).
- A long, clear function beats an unreadable `.map.filter.reduce` chain. No clever one-liners.
- Comments **explain the why**, never the what. If a comment paraphrases the code, delete it.

#### Tests

- Every critical business rule (dates, deduplication, retry, sync status) **must** have a unit test in `kPhotosTests`.
- Pure tests first (timeline logic, parsing). Tests touching Realm use an in-memory configuration.
- No tests on pure SwiftUI wiring. Target the logic, not the declaration.
- Test doubles must preserve ordering, async/throws behavior and the invariants of the real collaborator.
- Use in-memory Realm and synthetic files/transports. The XCTest host must not start real cloud preparation.
- Test pagination failure, stale scope/revision results, cancellation and partial metadata reads where relevant.
- Background changes also need device validation of suspension, resumption and interrupted transfers;
  passing unit tests alone cannot establish a complete real-library backup.

## Critical business rules and API

- `Photo.takenAt` comes from `PHAsset.creationDate` or embedded original metadata, never upload time.
  Cloud file dates are an explicitly approximate fallback. Preserve raw timezone-less EXIF values as local-time assumptions.
- Upload `created_at` is mandatory and comes from the asset capture date (current time only when absent).
  Timeline order is `takenAt` descending. File naming preserves capture date and reversible local identifier:
  `{YYYYMMDD}_{HHmmss}_{escapedLocalIdentifier}.{ext}`. The date and reversible identifier support correlation/deduplication;
  a filename alone never proves byte integrity or complete backup.

  ```swift
  uploadParams["created_at"] = Int((asset.creationDate ?? Date()).timeIntervalSince1970)
  ```

- Use `https://api.kdrive.infomaniak.com` for kDrive. See [docs/api/README.md](docs/api/README.md)
  and the official checked-in OpenAPI export; refresh before API PRs, at least monthly, or after a discrepancy.
- Upload body is octet-stream, metadata in query parameters; chunked upload above 50 MB is app policy.
  New originals use `conflict=error`; never overwrite originals. Albums use kDrive categories, not copies or folder moves.
- List at most 100 per request; follow every cursor. A missing required page/cursor is an error.
- Never write into system root ID 1. Discover the Private space through `DriveManager`.
  Browsing uses `existingRootFolder` and never creates folders.
- Shared quota: 60 requests per rolling window. Wait in the caller before constructing a request, not in `AuthInterceptor`.
  Visible media has priority 2, prefetch/listing 1, preparation 0. Reserve 20 slots from background-only work.
  Cancellation removes queued work; a visible request wakes the delay without bypassing total quota.
- Retry transient errors with exponential backoff, maximum three attempts. One failed upload must not block the queue.
- Responses use the Infomaniak envelope; normalize integer/string IDs in DTO decoding.
  See [API response conventions](docs/api/README.md#response-and-pagination-conventions).
- Downloads may redirect to signed temporary URLs. Never log or serialize these URLs, PATs, responses or personal IDs.
- Trash/rename/move may return undo information. Respect its validity window; do not treat trashing as permanent deletion.
- Any new behavior for retries, deduplication, dates or sync status requires a unit test. A failed asset is marked
  `error` and the queue continues; cancellation must not incorrectly mark a failure.

## Authentication and identity

See [`AuthService`](kPhotosCore/Auth/AuthService.swift), [`AuthConfig`](kPhotosCore/Auth/AuthConfig.swift),
[`OAuth2Client`](kPhotosCore/Auth/OAuth2Client.swift) and [`WebAuthCoordinator`](kPhotosFeatures/Auth/WebAuthCoordinator.swift).
The [API guide](docs/api/README.md#authentication-and-oauth-readiness) describes the checks required to re-enable OAuth.

- Active login uses a manually created PAT with `drive` scope, stored only in Keychain.
  `AuthService.acceptPAT(_:)` stores it through `TokenStorage`; `AuthInterceptor` supplies the Bearer header.
  PATs do not have a refresh token. Do not confuse a local expiry representation with provider-enforced validity.
  `AuthService.signOut()` wipes the stored credential.
  PAT authentication does not need an OAuth client ID. OAuth/PKCE code is inactive and ships with a placeholder.
  Do not infer universal OAuth restrictions or attestation requirements from one account's behavior.
- App identity is `app.kphotos` consistently in Debug/Release, Tuist and Makefile. Keep existing framework,
  background-task and callback namespaces compatible. Do not substitute identity at build time.
- Personal signing stays in ignored `.mise.local.toml` as `TUIST_KPHOTOS_DEVELOPMENT_TEAM`.
  Simulator builds require ad-hoc signing for Keychain; do not use `CODE_SIGNING_ALLOWED=NO`.
- Changing bundle identity does not migrate containers/Keychain. Preserve earlier installations until migration is verified.

## Realm and library safety

### Thread confinement and model contracts

Managed Realm objects can only be read on their owning thread. An `await` can resume elsewhere;
accessing a previously managed object after suspension can crash with an incorrect-thread exception.
Build a `Sendable` snapshot **inside** the Realm block and return that value instead of the object.
[`DriveSnapshot`](kPhotosCore/Drives/Drive.swift) and `DriveManaging` are the reference pattern.
Apply it to every new manager exposing persisted data across async/protocol boundaries.

The actual schema lives in [`kPhotosCore/Data/Models`](kPhotosCore/Data/Models).
`Photo` tracks capture date, cloud scope/revision, availability and backup verification;
`Album` tracks category-backed albums; `SyncCheckpoint` tracks scan progress;
`SyncSettings` tracks the selected library/options; `MetadataReadAttempt` retains preparation diagnostics.
Do not copy an old schema from documentation. Model and snapshot changes must stay consistent,
with explicit schema/migration review and in-memory tests for compatibility and derived states.

### Persistence, indexing and backup invariants

- All writes go through `RealmAccessor` on a background context. Models have primary keys.
  No managed Realm object may cross an async suspension or function return; build `Sendable` snapshots inside the Realm block.
- Migrate plaintext Realm through a separately verified encrypted copy. Retain the protected original in `DiagnosticBackups`.
  Never automatically rebuild after an unknown encryption-key error. Realm auxiliaries can be named pipes: inspect types before copying.
- Persist the exact selected drive/root. Compare folder name, drive and exact root ID on settings changes.
  An obsolete scan result/error must not replace the current gallery. Commit complete recursive indexes atomically.
  Hide stale entries without deleting originals. Only completed scans mark refresh success.
- Open from the local index; `LibraryRefreshSchedule` spaces automatic full checks by 15 minutes per scope.
  New selections and explicit pull-to-refresh check immediately.
- Gallery never reads ZIPs, Google sidecars, CSV catalogues or preparation journals.
  Exclude reserved raw/archive/journal/trash subtrees, while allowing explicitly selected roots to be browsed.
- Metadata comes from originals or a linked original PhotoKit asset; GPS must have this provenance and is never invented.
  `EmbeddedMetadataIndexer` prepares on Wi-Fi, independently of rendering, with foreground/background resumption.
  `MetadataIndexStore` owns retry selection and `MetadataReadAttempt` diagnostics. Pause persists per scope;
  explicit retry preserves history. Cancellation leaves the original pending. Partial reads remain distinguishable from complete reads without GPS.
- Images: progressive reads 64 KiB–32 MiB. Reject oversized responses ignoring Range before their body.
  Video metadata: bounded HTTPS ranges through `RemoteMediaAsset`, 32 MiB aggregate budget.
  AVFoundation receives neither signed HTTPS URL nor PAT. Playback shares transport without metadata byte cap and cancels on exit.
- `.kphotos-index` is app-owned derived metadata, capped at 32 MiB. Validate producer/schema/scope, revisions,
  root/drive and complete listing before batch import in one background write. Preserve client tokens across interruptions.
  Only verified app-owned caches may be versioned. No Mac worker or additional server.
- `ResourceBackup` verifies SHA-256 before reuse/completion. All PhotoKit resources and manifest must succeed.
  Keychain holds chunk resume state; a shared lock serializes foreground/background drains. Verification needs temporary disk space.
- Full backup completion requires eligible local assets matching available `backupComplete` originals in the exact scope
  and local modification date. Queue completion alone is insufficient. Limited permissions/filters describe selection completion.
  Recheck PhotoKit changes and foregrounding; queue notifications update details without requiring a Photo write.
- Do not claim a real library is complete because automated tests pass. iOS background execution has no guaranteed schedule.

## Rendering and interaction

- `ThumbnailRequestBroker` deduplicates drive/file/revision consumers; cancel only after the last consumer leaves.
  Gate thumbnail requests by viewport. Never enumerate, encode or trim cache directories during tile rendering.
  Disk work runs off-main on the owned serial queue; trim periodically.
  Budgets: thumbnails 96 MiB RAM / 512 MiB disk; previews 256 MiB disk; leave 128 MiB free. Never evict originals.
- Cloud Live Photos require exactly one still and one short video with matching embedded Apple content identifiers
  in the same scope; filenames alone never pair them. Keep both originals intact. Viewer, album, deletion and PhotoKit import
  actions carry both resources. ImageIO determines temporary file extension from real bytes; never rename cloud originals.
- Viewer separates page loading, zoom, information and actions. Native iOS 18+ source IDs must match the visible tile
  for local/cloud/synced media. Keep the current source thumbnail mounted after paging.
  Horizontal paging rejects vertical drags and zoomed photos; iOS 16–17 retains fallback gestures.
- Activity UI belongs inside gallery/map scroll content, not a top inset fighting the large title.
  Keep tab bar expanded (`.never`); use availability fallbacks for newer tabs/toolbars/roles. Keep map clustering in MKMapView.
- XCTest host must not start real cloud work. Keep unfinished actions out of the UI.

## Build, checks and contribution process

All ordinary build/check targets go through the root [Makefile](Makefile).
See [COMMANDS.md](COMMANDS.md) for simulator debugging, targeted tests and dependency maintenance.

```sh
make setup
make generate                 # resolves packages, applies Realm shim, generates workspace
make run-sim                  # default: iPhone 17
make run-sim SIMULATOR="iPhone 16e"
make test
make check-headers format-check lint-ci check-secrets
make dead-code
```

`make install` applies `scripts/prepare_realm.py`, the reviewed Realm Core/Xcode compatibility shim.
Revisit the shim on each Realm update; do not blindly patch changed upstream source.
Use `make generate` after adding/removing files or targets; editing existing source normally needs only an incremental build.
Do not erase an app container/database as a routine response to a migration error.

### Mandatory source header

Use the complete GPL-3.0 header in [file-header-template.txt](file-header-template.txt), including
`Copyright (C) 2026 Raphaël Dimeck`, in first-party Swift files, SwiftPM/Tuist manifests and executable scripts.
Keep shebangs and the Swift tools directive first. `make check-headers` validates the canonical text.

Keep SwiftLint's header `required_pattern` when changing severity. The header regex uses YAML `|-`.
SwiftFormat options must exist in the Mise-pinned version and exclude generated directories.
A formatter transformation that changes overload selection or concurrency behavior requires a focused correction and test.

### Conventional Commits

```text
feat(timeline): add date-grouped photo grid
fix(upload): preserve capture date in chunked upload
feat(albums): add category-backed album creation
refactor(core): split photo reading and writing protocols
test(sync): cover queue deduplication
docs(agents): clarify media safety rules
chore(deps): update reviewed package lockfile
```

Common scopes: `app`, `core`, `coreui`, `features`, `timeline`, `albums`, `upload`, `sync`, `widget`, `share`, `ci`, `deps`, `agents`.
Local agent work follows [WORKFLOW.md](WORKFLOW.md): coherent features, explicit validation before committing,
one feature per commit, no unsolicited branch/push/history rewrite. Public contributors use the PR process in
[CONTRIBUTING.md](CONTRIBUTING.md).

### Pre-PR / publication checklist

- [ ] Scope is coherent; unrelated working changes are preserved and the diff is reviewed.
- [ ] Critical behavior has tests; relevant unit tests pass. Sync/transport changes have appropriate device validation.
- [ ] `make check-headers format-check lint-ci` passes; remaining failures are reported, never hidden by weakening rules.
- [ ] `make dead-code` is reviewed; no new unused code is introduced.
- [ ] User-facing strings use `kPhotosResources`, with both localizations updated.
- [ ] Realm primary keys, snapshots, schema migration, background writes and revision/scope checks remain consistent.
- [ ] Original media is intact; backup completion is backed by resource verification, not only queue status.
- [ ] API changes match the refreshed official spec; discrepancies are investigated rather than guessed.
- [ ] `Tuist/Package.resolved` is versioned; dependency licenses/revisions and the Realm shim are reviewed when changed.
- [ ] Source GPL headers and third-party notices are preserved.
- [ ] `make check-secrets` passes; binary assets/screenshots are inspected separately.
- [ ] No credentials, signed URLs, account diagnostics, local paths, databases or real-library manifests are published.
- [ ] Local-only work stays under ignored `.local/`; personal signing stays in ignored `.mise.local.toml`.
- [ ] CI action updates retain immutable SHAs, minimal permissions and no persisted checkout credentials.
- [ ] Relevant docs are updated when structure, durable rules or public behavior change.
- [ ] Commit message follows Conventional Commits; required user validation has been obtained before committing.

Keep normative rules, their rationale and reusable procedures in docs. Keep device-session narratives,
one-off test counts, personal account observations and incident chronology in local review notes.
A past incident may justify a durable invariant; preserve the invariant and its regression test, not the session narrative.

## Ecosystem references

These projects provide architectural reference material; they do not imply affiliation or installed dependencies.

- [Infomaniak iOS kDrive](https://github.com/Infomaniak/ios-kDrive): API and photo-library interoperability patterns.
- [iOS SwissTransfer](https://github.com/Infomaniak/ios-SwissTransfer) and
  [iOS Euria](https://github.com/Infomaniak/ios-euria): modular iOS architecture conventions.
- [ios-core-ui](https://github.com/Infomaniak/ios-core-ui) and
  [ios-design-system](https://github.com/Infomaniak/ios-design-system): shared component patterns.
