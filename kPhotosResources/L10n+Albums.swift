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
    enum Albums {
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
}
