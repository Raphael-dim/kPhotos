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
    enum SyncOptions {
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
}
