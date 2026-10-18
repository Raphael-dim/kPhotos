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
    enum Viewer {
        public static let liveMotion = key("viewer.live.motion")
        public static let liveStill = key("viewer.live.still")
        public static let liveMotionUnavailable = key("viewer.live.unavailable")
        public static let addToAlbum = key("viewer.addToAlbum")
        public static let saveToLibrary = key("viewer.saveToLibrary")
        public static let saveToLibrarySuccess = key("viewer.saveToLibrarySuccess")
        public static let delete = key("viewer.delete")
        public static let deleteConfirmTitle = key("viewer.delete.confirm.title")
        public static let deleteConfirmMessage = key("viewer.delete.confirm.message")
        public static let albumsEmpty = key("viewer.albums.empty")
        public static let selectAlbumTitle = key("viewer.selectAlbum.title")

        public enum Info {
            public static var embeddedLocalDate: String { key("viewer.info.embeddedLocalDate") }
            public static var embeddedLocalDateExplanation: String { key("viewer.info.embeddedLocalDateExplanation") }
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
            public static let photoType = key("viewer.info.type.photo")
            public static let videoType = key("viewer.info.type.video")
            public static let resolution = key("viewer.info.resolution")
            public static let takenAt = key("viewer.info.takenAt")
            public static let fallbackDate = key("viewer.info.fallbackDate")
            public static let fallbackDateExplanation = key("viewer.info.fallbackDateExplanation")
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
}
