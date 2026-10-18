# Product scope

kPhotos is an independent iOS client focused on backing up and browsing photos/videos stored in kDrive.
Capture-date ordering and preservation of originals govern feature decisions.
This document records goals and boundaries; the [README](../README.md) describes current capabilities.
A planned feature is not an implementation commitment for the current change.

## v1 goals

- Infomaniak authentication, currently using a Personal Access Token.
- Automatic backup of the authorized iOS photo library to kDrive.
- Timeline grouped by month and ordered by capture date.
- Fullscreen viewing with zoom, swipe and video playback.
- Manual albums with creation and add/remove actions, using kDrive categories.
- Album sharing through a kDrive share link.
- Home-screen widgets: photo of the day and photos from previous years on this day.

Authentication, backup, browsing, fullscreen media and category-backed albums have implementation in the current tree.
Sharing and widgets remain goals; do not expose unfinished actions or assume their targets already exist.
Cloud-library browsing and original-metadata preparation support these goals without requiring a separate server.

## Follow-up goals

The original v2 scope includes sharing a single photo, multi-selection/batch actions, album sorting/filtering,
album-name search and multi-drive support. Some selection actions already exist; validate each capability in source
before calling it complete. Multi-drive browsing does not establish a safe cross-account database migration.

## Outside the product scope

- Face recognition and AI search.
- Automatic memories.
- Photo/video editing.
- A social feed or social publishing platform; exporting a share link or media through iOS remains distinct.

No Firebase/Google analytics. If diagnostics or analytics are introduced, preserve privacy, use the project's
intended Sentry/Matomo choices only with real integration, and document collection accurately.

## Acceptance boundaries

A feature must preserve original files and capture-date provenance, respect the shared network budget,
work with the selected drive/root, and describe PhotoKit permission limits honestly.
Do not promise continuous background sync, an exact preparation deadline or verified backup completion without resource evidence.
New scope needs a concrete user need and a reviewable change; do not add speculative services, targets or dependencies.
