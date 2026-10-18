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

public extension L10n {
    enum Timeline {
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
}
