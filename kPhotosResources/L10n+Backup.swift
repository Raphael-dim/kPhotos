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
    enum Backup {
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
}
