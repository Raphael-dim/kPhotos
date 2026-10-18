# Infomaniak kDrive API reference

[Official portal](https://developer.infomaniak.com/docs/api) · [OpenAPI snapshot](infomaniak_openapi.json)

The snapshot is the unmodified public export of the **kDrive category only**, downloaded on **2026-10-18**.
OpenAPI 3.1.0, 153 paths, `info.version=1.0.0`, MIT license as declared by Infomaniak.
The publisher's version field is not a freshness indicator.
SHA-256: `d4d61f7cce4e8a3b939752b5b0f215ed800770a5e96b4ba2ac7bb7f5283b25e2`.

Compared with the previous mixed-category export: four kDrive paths were added and 38 retained paths changed.
The legacy WebDAV import route is absent; non-kDrive categories were deliberately excluded.
No authenticated production request is needed to refresh this documentation.

## Why the snapshot is versioned

The unmodified export provides an offline reference for code review and reproducible API decisions.
Keep the official schema as the source of truth for paths, request formats and response fields;
project notes explain app-specific choices rather than duplicating whole schemas.
A documentation export does not prove that an authenticated operation succeeds for every account or permission level.

## Inspect the local specification

List the exported paths without contacting an account:

```sh
python3 - <<'PYTHON'
import json
from pathlib import Path
spec = json.loads(Path("docs/api/infomaniak_openapi.json").read_text())
for path in sorted(spec["paths"]):
    print(path)
PYTHON
```

Inspect a capability's parameters and body format:

```sh
python3 - <<'PYTHON'
import json
from pathlib import Path
spec = json.loads(Path("docs/api/infomaniak_openapi.json").read_text())
operation = spec["paths"]["/3/drive/{drive_id}/upload"]["post"]
for parameter in operation.get("parameters", []):
    print(parameter["in"], parameter["name"], "required" if parameter.get("required") else "optional")
print("Body types:", list(operation.get("requestBody", {}).get("content", {})))
PYTHON
```

## Refresh

```sh
./scripts/update_api_doc.sh
# Or validate and import an explicit export:
./scripts/update_api_doc.sh /path/to/official-export.json
```

The script uses the portal's public `/download?categories[0]=kDrive` export,
validates its structure and required routes, then replaces the snapshot atomically.
Review the route/schema diff and update this provenance paragraph and digest after each refresh.
Refresh before an API-layer PR, at least monthly, or when observed behavior differs.
Do not import a personalized/authenticated response or a signed URL into the repository.

## Application contract

- The application calls `https://api.kdrive.infomaniak.com`. Some official generated examples use the generic
  `api.infomaniak.com` host; do not copy that host into the client without verification.
- Active authentication is a PAT with `drive` scope, stored in Keychain. OAuth is inactive.
  Restrictions observed for an account do not establish universal third-party OAuth or attestation rules.
- List children with `GET /3/drive/{drive_id}/files/{file_id}/files`, `limit <= 100` and cursor pagination.
- Create directories with `POST /3/drive/{drive_id}/files/{file_id}/directory`, JSON `name` and `only_for_me`.
  Discover the writable Private space; system root ID 1 must never be used for writes.
- Simple upload: `POST /3/drive/{drive_id}/upload`, octet-stream body and query metadata including
  `directory_id`, `file_name`, `total_size`, `created_at`, `client_token`, `conflict=error`.
- Chunked uploads use `/upload/session/start`, `/{session_token}/chunk` and `/{session_token}/finish`.
  Preserve the capture date in the finish body. The app chooses chunking above 50 MB; this is not a claimed API maximum.
- Albums use `/2/drive/{drive_id}/categories` and file-category associations; they do not move originals.
- Thumbnails, previews and downloads use `/2/drive/{drive_id}/files/{file_id}/…`.
  Downloads can redirect to temporary signed URLs. Deletion is trashing; undo metadata is not a permanent-delete guarantee.
- Share a conservative 60-requests/minute app budget, including background preparation; cancel obsolete work.

See `Endpoint+*.swift` and `PhotoApiFetcher+*.swift` for implemented capabilities.
Public schema examples are illustrative data, not project account information.
`scripts/api_test*.sh` are manual probes that **write and trash test files**, log private responses,
and include intentionally invalid requests. Use a disposable test folder, never the main library, and never publish their output.

## Route quick reference

These are common app/probe operations. The official snapshot remains authoritative for complete schemas;
listing a route here does not imply a finished UI action.

| Operation | Method and route | Contract to preserve |
| --- | --- | --- |
| Discover drives | `GET /2/drive/init?with=drives` | Decode accessible drives, then discover Private space |
| List directory | `GET /3/drive/{drive_id}/files/{file_id}/files` | Cursor pagination; at most 100 per app request |
| Metadata | `GET /3/drive/{drive_id}/files/{file_id}` | Preserve file revision and date provenance |
| Create directory | `POST /3/drive/{drive_id}/files/{file_id}/directory` | JSON `name`, `only_for_me`; writable parent |
| Simple upload | `POST /3/drive/{drive_id}/upload` | Octet-stream; query metadata and capture date |
| Start chunk session | `POST /3/drive/{drive_id}/upload/session/start` | JSON session metadata; secure resume state |
| Send chunk | `POST /3/drive/{drive_id}/upload/session/{session_token}/chunk` | Session upload host; byte body and chunk metadata |
| Finish chunk session | `POST /3/drive/{drive_id}/upload/session/{session_token}/finish` | JSON capture date and verification |
| Categories / albums | `GET/POST /2/drive/{drive_id}/categories` | Category associations do not move originals |
| Thumbnail / preview | `GET /2/drive/{drive_id}/files/{file_id}/thumbnail` or `/preview` | Derived pixels, not original metadata provenance |
| Download | `GET /2/drive/{drive_id}/files/{file_id}/download` | Follow allowed signed redirects without exposing credentials |
| Trash | `DELETE /2/drive/{drive_id}/files/{file_id}` | Soft deletion; retain any available undo metadata |
| Rename | `POST /2/drive/{drive_id}/files/{file_id}/rename` | JSON `name`; review undo response |
| Search | `GET /3/drive/{drive_id}/files/search` | Query filters and cursor pagination |

## Response and pagination conventions

Infomaniak responses use an envelope such as:

```json
{
  "result": "success",
  "data": [],
  "cursor": "next-page-cursor",
  "has_more": true
}
```

Error responses expose an error code/description; translate them into typed API errors at the boundary.
`InfomaniakResponse<T>` handles ordinary data responses; `RemoteFileListDTO` retains the pagination fields.
`RemoteFileDTO` accepts integer or string IDs and normalizes them to strings.
Do not assume every operation has an identical `data` shape or ignore pagination fields through a generic wrapper.

For v3 listings, send `limit` and the returned `cursor`; do not substitute v2 `page` / `per_page` parameters.
`has_more=true` without a usable cursor is an invalid response. A recursive scan commits only after every page succeeds.
The app may retain the preceding index on failure; it must never interpret a failed page as an empty directory.

Uploads must send capture time as Unix seconds: the simple-upload `created_at` query parameter or chunk finish JSON field.
Keep a stable `client_token` while retrying an upload whose outcome is unknown.
Do not reuse a same-size file as a successful backup without verifying its bytes.
Undo information such as `cancel_id`/`valid_until` belongs to the relevant operation response;
check the current schema and validity rather than promising a fixed cancellation duration.

## Authentication and OAuth readiness

PAT mode uses the generic `drive` scope and a Bearer header supplied by `AuthInterceptor`.
`AuthService.acceptPAT(_:)` stores the credential through `TokenStorage` in Keychain.
PATs do not have OAuth refresh tokens; their real validity is controlled by the issuer, not the app's local expiry placeholder.
`AuthService.signOut()` clears stored credentials.

The OAuth implementation remains in `OAuth2Client`, `AuthConfig`, `WebAuthCoordinator`
and `SignInViewModel.signInWithOAuth()`. It is inactive and the shipped client identifier is a placeholder.
Re-enabling it requires:

1. Register/configure an OAuth application and confirm the requested kDrive access with Infomaniak.
2. Verify authorization, PKCE exchange, callback `app.kphotos://oauth/callback`, refresh and sign-out behavior.
3. Verify actual kDrive API access with the resulting token and required permissions.
4. Update the sign-in UI, localized guidance, tests and authentication documentation together.

Do not infer universal OAuth scope/attestation restrictions or a guaranteed whitelisting procedure from one account's response.
PAT-based sign-in must remain independent of an OAuth client identifier.

## Manual probes and discrepancies

`scripts/api_test.sh` explores authentication, reads, writes, move/copy and chunk session creation.
`scripts/api_test_advanced.sh` probes synthetic media upload, capture-date preservation, thumbnails/previews,
download integrity, rename and chunked transfer. These are live service probes, not offline unit tests.
They require `PAT`, `DRIVE_ID` and `TEST_FOLDER_ID` environment variables and a disposable folder owned by the tester.
Never run them as routine CI against a production library; they write/trash files and include intentionally rejected operations.
Treat output and temporary responses as private even when token fields are omitted from the console.

When behavior diverges, refresh the schema, compare the exact path/method/content type, verify the selected writable scope
and permissions, and reduce the case using synthetic data. Add a local transport/DTO regression test where possible.
Keep the durable constraint or workaround documented; avoid embedding account IDs, real files or a session transcript in public docs.
