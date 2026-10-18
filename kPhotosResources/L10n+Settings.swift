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
    enum Settings {
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
}
