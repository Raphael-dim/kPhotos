/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2026 Raphaël Dimeck

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

import Foundation

public enum L10n {
    public enum BackupSafety {
        public static let incomplete = key("backup.safety.incomplete")
        public static let integrity = key("backup.safety.integrity")
        public static let tooLarge = key("backup.safety.tooLarge")
        public static let busy = key("backup.safety.busy")
        public static let preview = key("backup.safety.preview")
        public static func partial(completed: Int, total: Int) -> String {
            String(format: key("backup.safety.partial"), completed, total)
        }
    }

    public enum Backup {
        public static let title = key("backup.status.title")
        public static let checking = key("backup.status.checking")
        public static let saving = key("backup.status.saving")
        public static let waiting = key("backup.status.waiting")
        public static let attention = key("backup.status.attention")
        public static let upToDate = key("backup.status.upToDate")
        public static let selectionComplete = key("backup.status.selectionComplete")
        public static let accessRequired = key("backup.status.accessRequired")
        public static let empty = key("backup.status.empty")
        public static let checkingDetail = key("backup.status.checkingDetail")
        public static let emptyDetail = key("backup.status.emptyDetail")
        public static let accessDetail = key("backup.status.accessDetail")
        public static let checkFailed = key("backup.status.checkFailed")
        public static func allSaved(_ count: Int) -> String {
            String(format: key("backup.status.allSaved"), count)
        }

        public static func selectionSaved(_ count: Int) -> String {
            String(format: key("backup.status.selectionSaved"), count)
        }

        public static func remaining(_ count: Int) -> String {
            String(format: key("backup.status.remaining"), count)
        }

        public static func savedCount(_ saved: Int, _ total: Int) -> String {
            String(format: key("backup.status.savedCount"), saved, total)
        }

        public static let uploading = key("backup.status.uploading")
        public static let queued = key("backup.status.queued")
        public static let retrying = key("backup.status.retrying")
        public static let failed = key("backup.status.failed")
        public static let skipped = key("backup.status.skipped")
        public static let unverified = key("backup.status.unverified")
        public static let queue = key("backup.status.queue")
        public static func viewQueue(_ count: Int) -> String {
            String(format: key("backup.status.viewQueue"), count)
        }

        public static let lastRun = key("backup.status.lastRun")
        public static let automaticOn = key("backup.status.automaticOn")
        public static let automaticOff = key("backup.status.automaticOff")
        public static let automaticOffComplete = key("backup.status.automaticOffComplete")
        public static let deviceScope = key("backup.status.deviceScope")
        public static let selectedScope = key("backup.status.selectedScope")
        public static let lastUpload = key("backup.status.lastUpload")
        public static let backgroundHelp = key("backup.status.backgroundHelp")
        public static func nextAttempt(_ time: String) -> String {
            String(format: key("backup.status.nextAttempt"), time)
        }
    }

    public enum Places {
        public static let inProgress = key("places.status.inProgress")
        public static func progress(_ completed: Int, _ total: Int) -> String {
            String(format: key("places.status.progress"), completed.formatted(), total.formatted())
        }

        public static func processedCount(_ completed: Int, _ total: Int) -> String {
            String(format: key("places.status.processedCount"), completed.formatted(), total.formatted())
        }

        public static let title = key("places.status.title")
        public static let checking = key("places.status.checking")
        public static let running = key("places.status.running")
        public static let paused = key("places.status.paused")
        public static let waiting = key("places.status.waiting")
        public static let attention = key("places.status.attention")
        public static let complete = key("places.status.complete")
        public static let completeDetail = key("places.status.completeDetail")
        public static let help = key("places.status.help")
        public static let noGPS = key("places.status.noGPS")
        public static let processed = key("places.status.processed")
        public static let resume = key("places.status.resume")
    }

    public enum Common {
        public static let more = key("common.more")
        public static let cancel = key("common.cancel")
        public static let confirm = key("common.confirm")
        public static let delete = key("common.delete")
        public static let share = key("common.share")
        public static let errorGeneric = key("common.error.generic")
        public static let retry = key("common.retry")
        public static let close = key("common.close")
        public static let done = key("common.done")
        public static let create = key("common.create")
    }

    public enum SignIn {
        public static let title = key("signIn.title")
        public static let subtitle = key("signIn.subtitle")
        public static let action = key("signIn.action")

        public enum PAT {
            public static let title = key("signIn.pat.title")
            public static let subtitle = key("signIn.pat.subtitle")
            public static let placeholder = key("signIn.pat.placeholder")
            public static let action = key("signIn.pat.action")
            public static let openManager = key("signIn.pat.openManager")
            public static let scopes = key("signIn.pat.scopes")
            public static let help = key("signIn.pat.help")
            public static let paste = key("signIn.pat.paste")

            public enum Error {
                public static let empty = key("signIn.pat.error.empty")
                public static let tooShort = key("signIn.pat.error.tooShort")
                public static let tooLong = key("signIn.pat.error.tooLong")
                public static let whitespace = key("signIn.pat.error.whitespace")
                public static let badCharacters = key("signIn.pat.error.badCharacters")
            }

            public enum Tutorial {
                public static func page(current: Int, total: Int) -> String {
                    String(format: key("signIn.pat.tutorial.page"), current, total)
                }

                public static let howTo = key("signIn.pat.tutorial.howTo")
                public static let title = key("signIn.pat.tutorial.title")
                public static let step1Title = key("signIn.pat.tutorial.step1.title")
                public static let step1Body = key("signIn.pat.tutorial.step1.body")
                public static let step2Title = key("signIn.pat.tutorial.step2.title")
                public static let step2Body = key("signIn.pat.tutorial.step2.body")
                public static let step3Title = key("signIn.pat.tutorial.step3.title")
                public static let step3Body = key("signIn.pat.tutorial.step3.body")
                public static let step4Title = key("signIn.pat.tutorial.step4.title")
                public static let step4Body = key("signIn.pat.tutorial.step4.body")
                public static let step5Title = key("signIn.pat.tutorial.step5.title")
                public static let step5Body = key("signIn.pat.tutorial.step5.body")
            }
        }
    }

    public enum Timeline {
        public static let cloudLoading = key("timeline.cloud.loading")
        public static let fastScroll = key("timeline.fastScroll")
        public static let title = key("timeline.title")
        public static let emptyTitle = key("timeline.empty.title")
        public static let emptySubtitle = key("timeline.empty.subtitle")
        public static let libraryTitle = key("timeline.library.title")
        public static func librarySubtitle(photos: Int, videos: Int) -> String {
            String(format: key("timeline.library.subtitle"), photos, videos)
        }

        public static let permissionTitle = key("timeline.permission.title")
        public static let permissionSubtitle = key("timeline.permission.subtitle")
        public static let permissionAction = key("timeline.permission.action")
        public static let permissionDeniedTitle = key("timeline.permission.denied.title")
        public static let permissionDeniedSubtitle = key("timeline.permission.denied.subtitle")
        public static let noDriveTitle = key("timeline.noDrive.title")
        public static let noDriveSubtitle = key("timeline.noDrive.subtitle")
        public static let syncAction = key("timeline.sync.action")
        public static let syncPreparing = key("timeline.sync.preparing")
        public static func syncProgress(processed: Int, total: Int) -> String {
            String(format: key("timeline.sync.progress"), processed, total)
        }

        public static func syncDone(uploaded: Int) -> String {
            String(format: key("timeline.sync.done"), uploaded)
        }

        public static func sectionCount(count: Int) -> String {
            String(format: key("timeline.section.count"), count)
        }

        public static func sectionMore(count: Int) -> String {
            String(format: key("timeline.section.more"), count)
        }

        public static let errorDetailTitle = key("timeline.error.detail.title")

        public enum Backup {
            public static let failureTitle = key("timeline.backup.failure.title")
            public static let retryItem = key("timeline.backup.retryItem")
            public static let skipItem = key("timeline.backup.skipItem")
            public static let retryAll = key("timeline.backup.retryAll")
            public static func retryAllCount(_ count: Int) -> String {
                String(format: key("timeline.backup.retryAll.count"), count)
            }

            public static func retriedAllToast(_ count: Int) -> String {
                String(format: key("timeline.backup.retriedAll.toast"), count)
            }
        }

        public enum Selection {
            public static let deleteTitle = key("timeline.selection.delete.title")
            public static func deleteMessage(count: Int) -> String {
                String(format: key("timeline.selection.delete.message"), count)
            }

            public static let deleted = key("timeline.selection.deleted")
            public static func deletedCount(count: Int) -> String {
                String(format: key("timeline.selection.deletedCount"), count)
            }

            public static func deleting(count: Int) -> String {
                String(format: key("timeline.selection.deleting"), count)
            }

            public static func addedToAlbum(album: String) -> String {
                String(format: key("timeline.selection.addedToAlbum"), album)
            }

            public static func downloadedToLibrary(count: Int) -> String {
                String(format: key("timeline.selection.downloadedToLibrary"), count)
            }
        }

        public enum Deletion {
            public static func failedToast(_ count: Int) -> String {
                String(format: key("timeline.deletion.failed.toast"), count)
            }

            public static let failureTitle = key("timeline.deletion.failure.title")
            public static let retryItem = key("timeline.deletion.retryItem")
            public static let cancelItem = key("timeline.deletion.cancelItem")
        }
    }

    public enum SyncOptions {
        public static let title = key("syncOptions.title")
        public static let automaticHeader = key("syncOptions.automatic.header")
        public static let autoSync = key("syncOptions.autoSync")
        public static let autoSyncFooter = key("syncOptions.autoSync.footer")
        public static let networkHeader = key("syncOptions.network.header")
        public static let wifi = key("syncOptions.wifi")
        public static let cellular = key("syncOptions.cellular")
        public static let networkFooter = key("syncOptions.network.footer")
        public static let mediaHeader = key("syncOptions.media.header")
        public static let photos = key("syncOptions.photos")
        public static let videos = key("syncOptions.videos")
        public static let mediaFooter = key("syncOptions.media.footer")
    }

    public enum Albums {
        public static let title = key("albums.title")
        public static let create = key("albums.create")
        public static let createPlaceholder = key("albums.create.placeholder")
        public static let noDriveTitle = key("albums.noDrive.title")
        public static let noDriveSubtitle = key("albums.noDrive.subtitle")
        public static let emptyTitle = key("albums.empty.title")
        public static let emptySubtitle = key("albums.empty.subtitle")
        public static let addPhoto = key("albums.addPhoto")
        public static let addPhotoPlaceholder = key("albums.addPhoto.placeholder")
        public static let emptyAlbumTitle = key("albums.emptyAlbum.title")
        public static let emptyAlbumSubtitle = key("albums.emptyAlbum.subtitle")
        public static let rename = key("albums.rename")
        public static let renameTitle = key("albums.rename.title")
        public static let delete = key("albums.delete")
        public static let deleteConfirmTitle = key("albums.delete.confirm.title")
        public static let deleteConfirmMessage = key("albums.delete.confirm.message")
        public static func photoCount(count: Int) -> String {
            String(format: key("albums.photo.count"), count)
        }
    }

    public enum Settings {
        public static let title = key("settings.title")
        public static let account = key("settings.account")
        public static let storage = key("settings.storage")
        public static let sync = key("settings.sync")
        public static let drivesEmpty = key("settings.drives.empty")
        public static let signOut = key("settings.signOut")
        public static let signOutConfirmTitle = key("settings.signOut.confirm.title")
        public static let signOutConfirmMessage = key("settings.signOut.confirm.message")
        public static let signOutConfirmAction = key("settings.signOut.confirm.action")
        public static let folderHeader = key("settings.folder.header")
        public static let folderPlaceholder = key("settings.folder.placeholder")
        public static let folderFooter = key("settings.folder.footer")
        public static let appearance = key("settings.appearance")
        public static let themeSystem = key("settings.theme.system")
        public static let themeLight = key("settings.theme.light")
        public static let themeDark = key("settings.theme.dark")
    }

    public enum Onboarding {
        public static let welcomeTitle = key("onboarding.welcome.title")
        public static let welcomeSubtitle = key("onboarding.welcome.subtitle")
        public static let permissionPhotos = key("onboarding.permission.photos")
        public static let permissionPhotosSubtitle = key("onboarding.permission.photos.subtitle")
    }

    public enum Upload {
        public static let statusPending = key("upload.status.pending")
        public static let statusUploading = key("upload.status.uploading")
        public static let statusSynced = key("upload.status.synced")
        public static let statusError = key("upload.status.error")
    }

    public enum Map {
        public static var completePlaces: String { key("map.metadata.complete") }
        public static func metadataLimited(count: Int) -> String { String(format: key("map.metadata.limited"), count) }
        public static var metadataHelp: String { key("map.metadata.help") }
        public static var suspendMetadata: String { key("map.metadata.suspend") }
        public static func metadataFailures(count: Int) -> String {
            String(format: key("map.metadata.failures"), count)
        }

        public static func metadataProgress(completed: Int, total: Int) -> String {
            String(format: key("map.metadata.progress"), completed, total)
        }

        public static let tabTitle = key("map.tab.title")
        public static let title = key("map.title")
        public static func subtitle(count: Int) -> String {
            String(format: key("map.subtitle"), count)
        }

        public static let loading = key("map.loading")
        public static let emptyTitle = key("map.empty.title")
        public static let emptySubtitle = key("map.empty.subtitle")
        public static let permissionTitle = key("map.permission.title")
        public static let permissionSubtitle = key("map.permission.subtitle")
        public static let permissionDeniedSubtitle = key("map.permission.denied.subtitle")
        public static let allowAccess = key("map.allowAccess")
        public static let openSettings = key("map.openSettings")
        public static func sheetTitle(count: Int) -> String {
            String(format: key("map.sheet.title"), count)
        }

        public static let placesSectionTitle = key("map.places.section.title")
        public static func placeItemsCount(count: Int) -> String {
            String(format: key("map.places.items.count"), count)
        }
    }

    public enum FolderPicker {
        public static let title = key("folderPicker.title")
        public static let selectThisFolder = key("folderPicker.selectThisFolder")
        public static let rootNotSelectable = key("folderPicker.rootNotSelectable")
        public static let createNewFolder = key("folderPicker.createNewFolder")
        public static let subfolders = key("folderPicker.subfolders")
        public static let noSubfolders = key("folderPicker.noSubfolders")
        public static let folderNamePlaceholder = key("folderPicker.folderNamePlaceholder")
        public static let back = key("folderPicker.back")
    }

    public enum Viewer {
        public static let addToAlbum = key("viewer.addToAlbum")
        public static let saveToLibrary = key("viewer.saveToLibrary")
        public static let saveToLibrarySuccess = key("viewer.saveToLibrarySuccess")
        public static let delete = key("viewer.delete")
        public static let deleteConfirmTitle = key("viewer.delete.confirm.title")
        public static let deleteConfirmMessage = key("viewer.delete.confirm.message")
        public static let albumsEmpty = key("viewer.albums.empty")
        public static let selectAlbumTitle = key("viewer.selectAlbum.title")

        public enum Info {
            public static let photoType = key("viewer.info.type.photo")
            public static let videoType = key("viewer.info.type.video")
            public static let title = key("viewer.info.title")
            public static let fileSection = key("viewer.info.file.section")
            public static let dateSection = key("viewer.info.date.section")
            public static let cameraSection = key("viewer.info.camera.section")
            public static let locationSection = key("viewer.info.location.section")
            public static let kdriveSection = key("viewer.info.kdrive.section")
            public static let videoSection = key("viewer.info.video.section")
            public static let name = key("viewer.info.name")
            public static let size = key("viewer.info.size")
            public static let type = key("viewer.info.type")
            public static let resolution = key("viewer.info.resolution")
            public static let takenAt = key("viewer.info.takenAt")
            public static let addedAt = key("viewer.info.addedAt")
            public static let duration = key("viewer.info.duration")
            public static let make = key("viewer.info.make")
            public static let lens = key("viewer.info.lens")
            public static let aperture = key("viewer.info.aperture")
            public static let shutter = key("viewer.info.shutter")
            public static let iso = key("viewer.info.iso")
            public static let focalLength = key("viewer.info.focalLength")
            public static let path = key("viewer.info.path")
            public static let hash = key("viewer.info.hash")
            public static let coordinates = key("viewer.info.coordinates")
            public static let openInMaps = key("viewer.info.openInMaps")
            public static let locationUnknown = key("viewer.info.locationUnknown")
        }
    }

    private static func key(_ key: String) -> String {
        NSLocalizedString(key, bundle: .kPhotosResources, comment: "")
    }
}

private final class BundleToken {}

public extension Bundle {
    static var kPhotosResources: Bundle {
        Bundle(for: BundleToken.self)
    }
}
