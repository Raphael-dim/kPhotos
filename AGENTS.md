# AGENTS.md — kPhotos (iOS)

> Persistent memory for AI agents working on kPhotos.
> Read this file end to end before modifying any code.

---

## 1. Project mission

**kPhotos** is an open source iOS client for **kDrive** (Infomaniak), dedicated to backing up and organizing photos and videos from the iOS photo library.

Independent project, not affiliated with Infomaniak Network SA. It relies on the public kDrive API and follows the conventions of the Infomaniak Generation 3 iOS projects so the codebase stays consistent with that ecosystem.

Photos are organized by capture date (`takenAt`, read from the `PHAsset`), not by upload date — that is the central guarantee of the app.

---

## 2. Tech stack (mandatory)

| Component         | Choice                                       |
|-------------------|----------------------------------------------|
| Language          | Swift 5.10                                   |
| UI                | SwiftUI first (UIKit only if required)       |
| Minimum iOS       | 16.6+                                        |
| Build system      | Tuist (project generation + SPM)             |
| Tool manager      | Mise                                         |
| Networking        | Alamofire (via ios-core-ui)                  |
| Database          | RealmSwift                                   |
| DI                | InfomaniakDI (`@InjectService`)              |
| Linting           | SwiftLint + SwiftFormat                      |
| Dead code         | Periphery                                    |
| Error tracking    | Sentry                                       |
| Analytics         | Matomo (never Firebase/Google)               |
| Translations      | Loco (`.import_loco.yml`)                    |
| CI/CD             | GitHub Actions                               |
| Code quality      | SonarCloud                                   |
| Commits           | Conventional Commits                         |
| License           | GPL-3.0                                      |

---

## 3. Context map (project structure)

```
ios-kPhotos/
├── kPhotos/                     # Main app target (SwiftUI App, lifecycle, root navigation)
│   ├── App/
│   └── Resources/
├── kPhotosCore/                 # Business logic — NO SwiftUI/UIKit imports
│   ├── Data/
│   │   ├── Api/                 # Endpoint*, PhotoApiFetcher*
│   │   ├── Models/              # Realm models (Photo, Album, SyncCheckpoint)
│   │   ├── Cache/               # *Manager (PhotoManager, AlbumManager, TimelineManager)
│   │   └── Database/            # RealmAccessor
│   ├── Upload/                  # BackgroundUploadSessionManager
│   ├── Sync/                    # PhotoSyncEngine
│   └── DI/                      # FactoryService
├── kPhotosCoreUI/               # Shared UI components (PhotoGrid, AlbumCard, FullscreenViewer…)
├── kPhotosFeatures/             # Feature modules (Timeline, Albums, Onboarding, Settings)
│   └── <Feature>/               # View + ViewModel
├── kPhotosResources/            # Assets.xcassets + *.lproj/
├── kPhotosShareExtension/       # Share sheet extension
├── kPhotosWidget/               # Widgets (PhotoOfTheDay, OnThisDay)
├── kPhotosTests/                # Unit tests (mirror source + Tests suffix)
├── kPhotosUITests/              # UI tests
├── Tuist/
│   ├── Package.swift            # SPM dependencies
│   └── ProjectDescriptionHelpers/
├── Project.swift                # Tuist project definition
├── .mise.toml                   # Tool versions
├── .swiftlint.yml / .swiftlint-ci.yml
├── .swiftformat
├── .periphery.yml
├── .import_loco.yml
├── .sonarcloud.properties
├── file-header-template.txt     # Mandatory GPL-3.0 header
└── AGENTS.md                    # This file
```

### Layer separation rule
- `kPhotosCore`: pure logic, Realm models, API, managers. **No** `import SwiftUI` / `import UIKit`.
- `kPhotosCoreUI`: reusable UI components (no business logic).
- `kPhotosFeatures`: ViewModels + Views per feature. ViewModels live HERE, never in Core.
- `kPhotos`: app assembly and root navigation only.

---

## 4. SPM dependencies (Tuist/Package.swift)

Currently resolved:

```swift
.package(url: "https://github.com/realm/realm-swift", from: "20.0.0"),
.package(url: "https://github.com/Alamofire/Alamofire", from: "5.10.0")
```

SwiftLint and SwiftFormat are installed via Mise (`.mise.toml`), not SPM.

`@InjectService` / `SimpleResolver` / `Factory` are provided by a local shim
(`kPhotosCore/DI/InjectService.swift`) that mirrors the InfomaniakDI API.
Swapping it for the real package later requires no consumer-side change.

Sentry, an Infomaniak login package, or ios-core-ui will be added if and when
the code that consumes them lands — YAGNI applies.

---

## 5. Code conventions

### Style
- `camelCase` for variables/functions, `PascalCase` for types.
- Max line width: **130 characters**.
- Indentation: **4 spaces**, line endings **LF**.
- Imports: grouped alphabetically, blank line after the block.
- SwiftUI: property wrappers **private** (`@State private`, `@StateObject private`, `@ObservedObject private`).
- Every source file starts with the GPL-3.0 header from `file-header-template.txt`.

### Strings
- **Always** go through the keys in `kPhotosResources`. No user-facing string literal in code.

### Dependency injection (InfomaniakDI)
```swift
// Registration (kPhotosCore/DI/FactoryService.swift)
FactoryService.store.register(PhotoManager.self) { PhotoManagerImpl() }

// Usage
@InjectService var photoManager: PhotoManager
```
Managers expose a **protocol** (e.g. `PhotoManager`), never the concrete class directly.

### API layer
- Extend `PhotoApiFetcher` for each capability via focused extensions:
  - `PhotoApiFetcher+Upload.swift`
  - `PhotoApiFetcher+Listing.swift`
  - `PhotoApiFetcher+Albums.swift`
- Endpoints in `Endpoint.swift` + extensions `Endpoint+Photos.swift`, `Endpoint+Albums.swift`.

### Concurrency
- **Always** `async/await` and structured concurrency.
- Never callbacks / completion handlers unless UIKit interop forces it.

### Realm persistence
- Thread-safe Realm models required (primary keys defined).
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
  - `PhotoManager` manages the photo index. It does **not** upload (→ `UploadQueue`), does not sync (→ `SyncEngine`), does not observe the iOS photo library (→ `PHPhotoLibraryObserver`).
  - If a type exceeds ~300 lines or its name contains "and" / "manager utility helper", it violates SRP.
- **O — Open / Closed.** Open for extension, closed for modification.
  - Adding a new API capability: create `PhotoApiFetcher+NewCapability.swift`, do not touch the original file.
  - Adding a media kind: go through an `enum MediaKind` + exhaustive switch (compile-time safety), not scattered `if`s.
- **L — Liskov Substitution.** Every protocol implementation must be substitutable without surprises.
  - A `MockPhotoManager` used in tests **must** respect the same invariants (ordering, async, throws) as `PhotoManagerImpl`.
- **I — Interface Segregation.** Many small protocols rather than one large one.
  - Do not expose a giant `PhotoManager`. Prefer `PhotoReading`, `PhotoWriting`, `PhotoSyncing`. A view that only reads injects `PhotoReading`.
- **D — Dependency Inversion.** Depend on abstractions, never on concrete classes.
  - Features depend on **protocols** resolved via `@InjectService` (InfomaniakDI). No `PhotoManagerImpl()` is instantiated directly outside of `FactoryService`.

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
- No chain of more than 2 consecutive accesses across different objects. If you write one, add a method on the intermediate object.

#### Fail fast at the boundaries, never in the middle
- Validation **only at boundaries** (user input, API response, data loaded from the iOS photo system). Past that, trust the types.
- Errors are **typed and local**: `PhotoAPIError`, `UploadError`, `SyncError`. No generic `Error` propagated.
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
- Every critical business rule (§6 — dates, deduplication, retry, sync status) **must** have a unit test in `kPhotosTests`.
- Pure tests first (timeline logic, parsing). Tests touching Realm use an in-memory configuration.
- No tests on pure SwiftUI wiring. Target the logic, not the declaration.

---

## 6. Critical business rules

### Dates (central guarantee — NEVER bypass)
1. `Photo.takenAt` = `PHAsset.creationDate`. Never the upload date.
2. On upload, the request **mandatorily** includes:
   ```swift
   uploadParams["created_at"] = Int(asset.creationDate?.timeIntervalSince1970
                                    ?? Date().timeIntervalSince1970)
   ```
3. The timeline is sorted by `takenAt` desc. Never by `uploadedAt`.

### Uploaded file naming convention
```
{YYYYMMDD}_{HHmmss}_{PHAsset.localIdentifier}.{ext}
```
Encodes the date in the name as a fallback if `created_at` is corrupted server-side,
avoids collisions between devices, and serves as a deduplication key.

### kDrive tree
```
kDrive/kPhotos/
├── {YYYY}/{MM}/<files>
└── albums/<AlbumName>/
```

---

## 7. Realm models (reference)

See `kPhotosCore/Data/Models/`. Reference schema:

```swift
class Photo: Object {
    @Persisted(primaryKey: true) var fileId: String = ""   // kDrive file ID
    @Persisted var driveId: Int = 0
    @Persisted var localIdentifier: String = ""            // PHAsset.localIdentifier
    @Persisted var name: String = ""
    @Persisted var takenAt: Date = Date()                  // SOURCE OF TRUTH for the timeline
    @Persisted var uploadedAt: Date = Date()
    @Persisted var mimeType: String = ""
    @Persisted var size: Int64 = 0
    @Persisted var thumbnailUrl: String = ""
    @Persisted var isVideo: Bool = false
    @Persisted var duration: Double = 0
    @Persisted var albumIds: List<String>
    @Persisted var syncStatus: String = "synced"           // pending | uploading | synced | error
    @Persisted var isFavorite: Bool = false
}

class Album: Object {
    @Persisted(primaryKey: true) var id: String = ""       // kDrive folder ID
    @Persisted var driveId: Int = 0
    @Persisted var name: String = ""
    @Persisted var coverPhotoId: String = ""
    @Persisted var photoCount: Int = 0
    @Persisted var createdAt: Date = Date()
    @Persisted var isShared: Bool = false
}

class SyncCheckpoint: Object {
    @Persisted(primaryKey: true) var driveId: Int = 0
    @Persisted var lastSyncedAt: Date = Date()
    @Persisted var lastCursor: String = ""
}
```

---

## 8. kDrive API

### Source of truth: official OpenAPI spec

**Official doc versioned in the repo**: [`docs/api/infomaniak_openapi.json`](docs/api/infomaniak_openapi.json) (~1.6 MB, OpenAPI 3.1).
See [`docs/api/README.md`](docs/api/README.md) for usage conventions.

⚠️ **The spec evolves on the Infomaniak side.** Re-download via `./scripts/update_api_doc.sh`:
- before every PR that touches the API layer,
- at least once a month,
- if real behavior diverges from the local spec.

### Authentication

Personal Access Token (PAT) in `Authorization: Bearer <token>` — see §20.

**Rate limit: 60 req/min** (non-negotiable; enforce via aggressive Realm caching + UI debouncing).

### Host

**All** kDrive endpoints (`/2/drive/...` and `/3/drive/...`) live on:

```
https://api.kdrive.infomaniak.com
```

(The legacy `api.infomaniak.com` is the general Infomaniak API — mail, sms, etc. — not kDrive.)

### Drive tree

```
/  (id=1, SYSTEM root, NOT writable)
└── Private  (visibility="is_private_space", writes allowed here)
    └── kPhotos  (our root folder, created on first sync)
        └── Library/YYYY/MM/  (Option 4 — upcoming)
```

**Critical rule**: NEVER hardcode `parent_id=1` for write operations. Always go through the Private space. Auto-discovery in code via `DriveManager.ensurePrivateSpace()`.

### Endpoints used by kPhotos

| Action                     | Method  | Endpoint                                                      | Notes |
|----------------------------|---------|---------------------------------------------------------------|-------|
| List drives                | GET     | `/2/drive/init?with=drives`                                   | Also returns users, teams |
| List a folder              | GET     | `/3/drive/{drive_id}/files/{folder_id}/files?limit=100&cursor=...` | **Cursor pagination** |
| File/folder metadata       | GET     | `/3/drive/{drive_id}/files/{file_id}`                         | |
| **Upload (≤ 50 MB)**       | POST    | `/3/drive/{drive_id}/upload?directory_id=&file_name=&total_size=&created_at=&conflict=version` | **Body = octet-stream, metadata in the query** |
| Chunked upload — start     | POST    | `/3/drive/{drive_id}/upload/session/start`                    | JSON body, returns `upload_url` |
| Chunked upload — chunk     | POST    | `{upload_url}/3/drive/{drive_id}/upload/session/{token}/chunk?chunk_number=&chunk_size=` | Body = octet-stream |
| Chunked upload — finish    | POST    | `/3/drive/{drive_id}/upload/session/{token}/finish`           | Body `{ "created_at": ts }` to set the final date |
| Create a folder            | POST    | `/3/drive/{drive_id}/files/{parent_id}/directory`             | Body `{ "name": ..., "only_for_me": true }` |
| Move a file                | POST    | `/3/drive/{drive_id}/files/{file_id}/move/{destination_id}`   | |
| Copy a file                | POST    | `/3/drive/{drive_id}/files/{file_id}/copy/{destination_id}`   | |
| Trash (soft delete)        | DELETE  | `/2/drive/{drive_id}/files/{file_id}`                         | Returns `cancel_id` (5 min undo) |
| Rename                     | POST    | `/2/drive/{drive_id}/files/{file_id}/rename`                  | Body `{ "name": ... }`, returns `cancel_id` |
| Thumbnail                  | GET     | `/2/drive/{drive_id}/files/{file_id}/thumbnail`               | image/jpeg |
| Preview                    | GET     | `/2/drive/{drive_id}/files/{file_id}/preview`                 | image/jpeg, height/width options |
| Download                   | GET     | `/2/drive/{drive_id}/files/{file_id}/download`                | **HTTP 302** → signed temporary URL (follow redirect) |
| Search                     | GET     | `/3/drive/{drive_id}/files/search?type=image&limit=100`       | Cross-folder |

### Cross-cutting conventions

- **Response envelope**: `{ "result": "success" | "error", "data": <T>, "error": { code, description }, "cursor", "has_more" }`. Captured by `InfomaniakResponse<T>`.
- **Flexible IDs**: kDrive sometimes returns `id` as Int, sometimes as String. Our `RemoteFileDTO.init(from:)` accepts both and normalizes to String.
- **v3 pagination**: cursor-based. While `has_more`, issue another GET with `?cursor=<value>`.
- **`cancel_id` undo**: `DELETE`, `rename`, `move` return `{ cancel_id, valid_until }`. ~5 min cancellation window. Useful for an "Undo" UX in v2.
- **Capture date**: `created_at` (unix seconds) as a query param on upload, or in the `finish` body for chunked. **kDrive accepts and preserves it** (verified, see `scripts/api_test_advanced.sh` T2).

### Empirical validation

Two scripts maintained in the repo to verify real behavior:
- [`scripts/api_test.sh`](scripts/api_test.sh) — covers auth, read, write, move, copy, chunked start
- [`scripts/api_test_advanced.sh`](scripts/api_test_advanced.sh) — covers real JPEG upload, **date preservation**, thumbnail, preview, download round-trip, rename, full chunked

---

## 9. Architecture rules (the 23 rules)

### Architecture
1. `kPhotosCore` **never** imports SwiftUI or UIKit.
2. Managers expose **protocols**, never concrete classes directly.
3. Every SwiftUI view observes Realm via `@ObservedResults` or a dedicated ViewModel.
4. ViewModels live in `kPhotosFeatures`, never in `kPhotosCore`.
5. Async code: **always** `async/await`, never callbacks.

### Dates (critical)
6. `Photo.takenAt` = `PHAsset.creationDate` — never the upload date.
7. On upload, API `created_at` = `asset.creationDate?.timeIntervalSince1970`.
8. Timeline sorted by `takenAt`, never by `uploadedAt`.

### Naming
9. Capability extensions: `Type+Capability.swift` pattern.
10. Endpoints: `Endpoint+Photos.swift`, `Endpoint+Albums.swift`.
11. Features: `Feature` suffix.
12. ViewModels: `ViewModel` suffix.
13. Tests: mirror source + `Tests` suffix.

### Security
14. No token / credential in source code or logs.
15. Keychain only for OAuth tokens.
16. Sentry logs anonymized — no `fileId`, no personal info.

### Performance
17. Thumbnails: Realm cache first, API as fallback.
18. Timeline listing: 100 items max per request.
19. Chunked upload for files > **50 MB** (kDrive BackgroundUpload pattern).
20. Realm background context for writes, main context for UI reads.

### Errors
21. Typed API errors (`PhotoAPIError`, `UploadError`, …).
22. Network errors retried with exponential backoff, **max 3 attempts**.
23. A file that fails to upload **does not block** the queue: `syncStatus = "error"`, move on.

---

## 10. MVP features

### Must-have v1
- Infomaniak authentication (PAT — see §20).
- Auto-sync iOS photo library → kDrive.
- Timeline grouped by month, sorted by `takenAt` desc.
- Detail view (fullscreen, zoom, swipe).
- Built-in video player.
- Manual albums (creation, add/remove).
- Album sharing (kDrive share link).
- Home screen widget: "Photo of the day" / "On this day X years ago".

### Nice-to-have v2
- Sharing a single photo.
- Multi-select + batch.
- Sorting/filtering inside albums.
- Search inside albums (by name).
- Multi-drive.

### Out of scope
- Face recognition, AI search, auto-memories, editing, social sharing.

---

## 11. Sync engine architecture

```
PHPhotoLibrary
   → SyncEngine
   → UploadQueue (Realm)
   → BackgroundURLSession
   → kDrive API
   → PhotoManager (Realm index)
   → TimelineManager
   → SwiftUI Views (@Published / @ObservedResults)
```

### iOS background constraints (to surface in onboarding)
- Background URLSession: ~30s after the app is closed.
- `BGAppRefreshTask`: ~30s every ~15min depending on iOS.
- At night (charging + Wi-Fi): several hours available.

**Never** promise real-time background sync.

---

## 12. Mandatory file header

Every `.swift` file starts with:

```swift
/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
```

Source: `file-header-template.txt` (project root).

---

## 13. Conventional Commits

Mandatory format:

```
feat(timeline): add date-grouped photo grid
fix(upload): correctly set created_at from PHAsset.creationDate
feat(albums): implement album creation via kDrive folder API
refactor(core): extract PhotoRepository protocol
test(sync): add unit tests for SyncEngine deduplication
docs(agents): update context map with new CoreUI components
chore(deps): bump RealmSwift to 10.x
```

Common scopes: `app`, `core`, `coreui`, `features`, `timeline`, `albums`,
`upload`, `sync`, `widget`, `share`, `ci`, `deps`, `agents`.

---

## 14. Build / lint / test commands

All targets go through the `Makefile` at the project root.

```bash
make setup       # mise install (tuist, swiftlint, swiftformat, periphery)
make install     # tuist install (resolves SPM packages)
make generate    # tuist generate --no-open (produces kPhotos.xcworkspace)
make open        # open kPhotos.xcworkspace
make build       # xcodebuild build (iPhone 17 by default)
make run-sim     # build + boot simulator + install + launch (one-shot)
make test        # xcodebuild test
make lint        # swiftlint --strict
make format      # swiftformat .
make clean       # removes DerivedData and generated files
```

Simulator override:

```bash
make run-sim SIMULATOR="iPhone 16e"
```

### First launch (cold start)

```bash
make setup && make generate && make run-sim
```

The first SPM resolution downloads Realm + Alamofire (~150 MB) and takes
3–5 minutes. Subsequent builds are incremental.

---

## 15. Pre-PR checklist

- [ ] `swiftlint` clean (CI config `.swiftlint-ci.yml`).
- [ ] `swiftformat` applied.
- [ ] `periphery scan` clean (no new dead code introduced).
- [ ] Conventional Commits respected.
- [ ] User-facing strings localized in `kPhotosResources`.
- [ ] Realm models with primary keys defined.
- [ ] Background upload/download tested if you touched sync.
- [ ] GPL-3.0 header present on new files.
- [ ] No token / credential / `fileId` in logs.
- [ ] `AGENTS.md` updated if structure or rules changed.

---

## 16. Known pitfalls

1. **`created_at` mandatory on upload** (see §6) — that's the condition for the timeline to stay sorted by capture date. Verified empirically: kDrive accepts and preserves the date passed as a query param (`scripts/api_test_advanced.sh` T2).
2. **iOS background sync** — Apple is strict. Don't promise real time; communicate the reality in the UX.
3. **60 req/min rate limit** — aggressive caching is mandatory; never re-fetch what's already in Realm.
4. **kDrive system root (id=1) is not writable** — a `POST .../files/1/directory` or an upload `directory_id=1` returns 400 `permission_denied`. Always go through the **Private** space (visibility="is_private_space"). `DriveManager.ensurePrivateSpace()` handles it automatically.
5. **Upload = octet-stream + query params** — definitely NOT multipart. The OpenAPI spec says so clearly (`requestBody: application/octet-stream`), and the server returns 422 `validation_failed` if you try multipart.
6. **v3 pagination = cursor + limit**, not `page` + `per_page` (that's v2). While `has_more`, re-issue a GET with `?cursor=<value>`.
7. **`drive:file:*` and `drive:management:*` are NOT in the list of scopes selectable on a PAT** — but the generic `drive` scope is enough for 99% of operations (create/upload/list/move inside the Private space). Verified.
8. **Download goes through a 302** to a signed temporary URL. Follow redirects (`AF.session.redirectHandler` or `-L` in curl).
9. **DELETE and rename return a `cancel_id`** — soft-delete with a 5 min undo window. Not a bug, it's the kDrive convention.
10. **GPL-3.0 license** — any dependency and any integrated source code must be compatible.

---

## 17. External references

- Reference AGENTS.md (inspiration): https://github.com/Infomaniak/ios-kDrive/blob/master/AGENTS.md
- iOS Gen 3 architecture: https://github.com/Infomaniak/ios-SwissTransfer · https://github.com/Infomaniak/ios-euria
- Existing kDrive photo logic: https://github.com/Infomaniak/ios-kDrive/tree/master/kDriveCore/Utils/PHAsset · https://github.com/Infomaniak/ios-kDrive/tree/master/kDrive/UI/Controller/Photo
- KMP core (future Android extension): https://github.com/Infomaniak/multiplatform-SwissTransfer
- Shared iOS libraries: https://github.com/Infomaniak/ios-core-ui · https://github.com/Infomaniak/ios-design-system

---

## 20. Authentication strategy

### Active mode: Personal Access Token (PAT)

kPhotos uses a **manually created PAT** generated by the user on Infomaniak Manager:
`Manager → My profile → API tokens → Create a token`.

**Why not OAuth?** The OAuth `client_id` obtained self-service via Manager (cf. *Add and manage Infomaniak API applications*) is limited to OIDC scopes (`openid`, `profile`, `email`, `phone`). A third-party OAuth token returns 401 on `api.kdrive.infomaniak.com`. The `drive` scope and its sub-scopes (`drive:file:*`, `drive:management:*`) are effectively granted only to Infomaniak's first-party apps (kDrive, Mail, etc.) via Apple attestation + server-side whitelisting — not available to third-party clients.

The PAT, on the other hand, is created from the user account on Manager and accepts the generic `drive` scope. **Verified empirically** (see `scripts/api_test*.sh`): this scope is enough to list, create folders (inside the Private space), upload, move, copy, rename, delete.

**Scopes to tick in Manager**:
- `drive` (generic, "Drive products") — **enough for everything kPhotos needs**
- The granular sub-scopes `drive:file:*` / `drive:management:*` do **not** appear in the Manager scope picker for third-party PATs; they are reserved for tokens derived through attestation.

**Validity**: `Unlimited` (the token does not refresh — no `refresh_token` on the PAT side).

### Code

- `AuthService.acceptPAT(_:)` ([kPhotosCore/Auth/AuthService.swift](kPhotosCore/Auth/AuthService.swift)): saves the typed token to the Keychain via `TokenStorage`. Creates an `AuthToken` with `expiresAt = +10y` and `refreshToken = nil`.
- `AuthInterceptor` ([kPhotosCore/Auth/AuthInterceptor.swift](kPhotosCore/Auth/AuthInterceptor.swift)): adds the Bearer to every request, unchanged.
- The [`SignInView`](kPhotosFeatures/Auth/SignInView.swift) screen offers a paste field + a link to Manager.

### Path back to OAuth (the day Infomaniak whitelists the `client_id`)

The full OAuth code is **kept** but inactive:
- [`OAuth2Client`](kPhotosCore/Auth/OAuth2Client.swift), [`WebAuthCoordinator`](kPhotosFeatures/Auth/WebAuthCoordinator.swift), [`AuthConfig`](kPhotosCore/Auth/AuthConfig.swift) with the Infomaniak `client_id` and `redirect_uri` `app.kphotos://oauth/callback`.
- `AuthServiceImpl.signIn(using:)` remains functional.
- `SignInViewModel.signInWithOAuth()` is ready to use.

To re-enable OAuth:
1. Get the `client_id` whitelisted on the Infomaniak side (support ticket, ask for the `drive` scope + App Attest token derivation).
2. In [`SignInView`](kPhotosFeatures/Auth/SignInView.swift), replace the "Validate token" button with one calling `viewModel.signInWithOAuth()`.
3. Remove / hide the paste field.

No change is required in the rest of the stack (`AuthInterceptor`, API layer, DI).

### Security (cross-reference to rules 14/15)

- The PAT lives **only** in the Keychain (`KeychainTokenStorage`).
- Never logged, never serialized outside of the Keychain.
- Sign-out via `AuthService.signOut()` wipes the Keychain.

---

## 21. Realm — golden rule on thread safety

Managed Realm `Object`s have **strict thread affinity**: they can only be read on the thread that opened the Realm. With Swift Concurrency, after an `await`, the resumption can land on any thread → a later access to `managedObject.id` crashes with `RLMException: Realm accessed from incorrect thread`.

**Rule**: no managed `Object`-Realm ever crosses an `async/await` boundary or a function return. Instead, define a **snapshot value type** (`Sendable`) built *inside* the Realm block.

**Applied example**: [`DriveSnapshot`](kPhotosCore/Drives/DriveSnapshot.swift) returned by `DriveManaging.refreshFromServer()`, `allDrives()`, `selectedDrive()`. The `Drive` type (Realm `Object`) stays internal to `DriveManagerImpl`.

Replicate this for every new manager that exposes Realm data through `async` or a protocol.

---
