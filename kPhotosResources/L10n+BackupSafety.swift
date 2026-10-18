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
    enum BackupSafety {
        public static let incomplete = key("backup.safety.incomplete")
        public static let integrity = key("backup.safety.integrity")
        public static let tooLarge = key("backup.safety.tooLarge")
        public static let busy = key("backup.safety.busy")
        public static let preview = key("backup.safety.preview")
        public static func partial(completed: Int, total: Int) -> String {
            String(format: key("backup.safety.partial"), completed, total)
        }
    }
}
