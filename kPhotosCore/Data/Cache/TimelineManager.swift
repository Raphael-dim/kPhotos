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
import RealmSwift

public struct TimelineSection: Identifiable, Equatable {
    public let id: String
    public let year: Int
    public let month: Int
    public let photoFileIds: [String]

    public init(year: Int, month: Int, photoFileIds: [String]) {
        self.id = "\(year)-\(String(format: "%02d", month))"
        self.year = year
        self.month = month
        self.photoFileIds = photoFileIds
    }
}

public protocol TimelineReading: AnyObject {
    /// Construit les sections triées par mois desc à partir de `takenAt`.
    /// Source de vérité métier : §6 AGENTS.md — JAMAIS basé sur uploadedAt.
    func buildSections() throws -> [TimelineSection]
}

public final class TimelineManagerImpl: TimelineReading {
    private let realm: RealmAccessor
    private let calendar: Calendar

    public init(realm: RealmAccessor, calendar: Calendar = .iso8601) {
        self.realm = realm
        self.calendar = calendar
    }

    public func buildSections() throws -> [TimelineSection] {
        try realm.read { realm in
            let photos = realm.objects(Photo.self).sorted(byKeyPath: "takenAt", ascending: false)
            return Self.groupByYearMonth(photos: photos, calendar: calendar)
        }
    }

    /// Fonction pure — testable sans Realm en injectant une Results-like.
    static func groupByYearMonth(
        photos: some Sequence<Photo>,
        calendar: Calendar
    ) -> [TimelineSection] {
        var buckets: [String: (year: Int, month: Int, ids: [String])] = [:]
        var order: [String] = []

        for photo in photos {
            let components = calendar.dateComponents([.year, .month], from: photo.takenAt)
            guard let year = components.year, let month = components.month else { continue }
            let key = "\(year)-\(String(format: "%02d", month))"
            if buckets[key] == nil {
                buckets[key] = (year, month, [])
                order.append(key)
            }
            buckets[key]?.ids.append(photo.fileId)
        }

        return order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return TimelineSection(year: bucket.year, month: bucket.month, photoFileIds: bucket.ids)
        }
    }
}

public extension Calendar {
    static let iso8601: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
}
