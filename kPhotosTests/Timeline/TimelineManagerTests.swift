/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

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

import XCTest
@testable import kPhotosCore

/// Vérifie la règle métier centrale §6 d'AGENTS.md :
/// la timeline est groupée par mois et ordonnée par `takenAt` desc — JAMAIS par `uploadedAt`.
final class TimelineManagerTests: XCTestCase {
    func testGroupByYearMonth_ordersSectionsByTakenAtDesc() {
        let calendar = Calendar.iso8601

        let photoOldest = makePhoto(id: "a", takenAt: date(2023, 1, 5), uploadedAt: date(2025, 12, 31))
        let photoMiddle = makePhoto(id: "b", takenAt: date(2024, 6, 12), uploadedAt: date(2024, 7, 1))
        let photoNewest = makePhoto(id: "c", takenAt: date(2025, 3, 28), uploadedAt: date(2024, 1, 1))

        // Délibérément triés par takenAt desc avant groupage — comme le ferait Realm.
        let sorted = [photoNewest, photoMiddle, photoOldest]
        let sections = TimelineManagerImpl.groupByYearMonth(photos: sorted, calendar: calendar)

        XCTAssertEqual(sections.map(\.id), ["2025-03", "2024-06", "2023-01"])
    }

    func testGroupByYearMonth_groupsSameMonthTogether() {
        let calendar = Calendar.iso8601

        let p1 = makePhoto(id: "1", takenAt: date(2025, 5, 1), uploadedAt: date(2025, 5, 2))
        let p2 = makePhoto(id: "2", takenAt: date(2025, 5, 28), uploadedAt: date(2025, 6, 1))
        let p3 = makePhoto(id: "3", takenAt: date(2025, 4, 15), uploadedAt: date(2025, 4, 16))

        let sections = TimelineManagerImpl.groupByYearMonth(photos: [p2, p1, p3], calendar: calendar)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].id, "2025-05")
        XCTAssertEqual(Set(sections[0].photoFileIds), Set(["1", "2"]))
        XCTAssertEqual(sections[1].id, "2025-04")
        XCTAssertEqual(sections[1].photoFileIds, ["3"])
    }

    func testGroupByYearMonth_ignoresUploadedAt() {
        // Régression : une photo récente uploadée tardivement doit rester groupée par takenAt.
        let calendar = Calendar.iso8601
        let recentPhotoUploadedNow = makePhoto(id: "x",
                                               takenAt: date(2020, 7, 10),
                                               uploadedAt: date(2026, 1, 1))

        let sections = TimelineManagerImpl.groupByYearMonth(photos: [recentPhotoUploadedNow],
                                                            calendar: calendar)

        XCTAssertEqual(sections.first?.id, "2020-07")
    }

    // MARK: - Helpers

    private func makePhoto(id: String, takenAt: Date, uploadedAt: Date) -> Photo {
        let photo = Photo()
        photo.fileId = id
        photo.takenAt = takenAt
        photo.uploadedAt = uploadedAt
        return photo
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar.iso8601.date(from: components) ?? Date()
    }
}
