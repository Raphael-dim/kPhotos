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
    enum Places {
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
}
