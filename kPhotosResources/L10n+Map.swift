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
    enum Map {
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
}
