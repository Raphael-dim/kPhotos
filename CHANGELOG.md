# Changelog

User-visible changes are recorded here. Unreleased entries describe the working tree, not a published release.

## Unreleased

### Added

- Recursive cloud library indexing, original-media metadata preparation and map locations.
- Verified Live Photo pairing, fullscreen paging and zoom, and media information sheets.
- Resumable chunked uploads and SHA-256 verification of backup resources.
- App-owned metadata index export and restore, validated against the selected library and file revisions.
- Backup and metadata-preparation details with scoped progress, pause and retry controls.

### Changed

- Gallery opens from its local index; automatic full scans have a 15-minute cooldown.
- Bounded image caches and shared request scheduling prioritize visible media within the API budget.
- Encrypted Realm storage and verified migration preserve existing data on migration failure.
- Native navigation adapts to newer iOS versions while retaining iOS 16.6 compatibility.
- Independent application identity is `app.kphotos`; signing configuration stays local.
- Public documentation now separates usage, architecture and API maintenance from development session notes.

### Fixed

- Capture dates and GPS retain their provenance; file dates remain approximate and missing GPS is never invented.
- Obsolete folder scan results cannot replace the current library; incomplete scans never commit partial indexes.
- Backup completion requires all eligible resources to match the selected scope and current asset revision.
- Canceled media requests release their place in the API queue.
- Token setup requests the `drive` scope rather than all account permissions.

### Limitations

- Large-library preparation, background execution and recovery require device validation beyond unit tests.
- Partial metadata reads may omit information present elsewhere in an original.
- Changing accounts, drives or application identity is not a validated automatic data-migration workflow.
