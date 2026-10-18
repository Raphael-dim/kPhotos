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
@testable import kPhotosCore
@testable import kPhotosFeatures
import XCTest

final class LivePhotoPairingTests: XCTestCase {
    private let identifier = "7142ABE5-762C-47C1-B1D6-92BF978C2152"

    func testSameAppleIdentifierMakesOneGalleryItemEvenWhenFilenamesDiffer() throws {
        let still = try photo(id: "still", name: "IMG_0340(1).HEIC", identifier: identifier)
        let motion = try photo(id: "motion", name: "IMG_0340.MP4", identifier: identifier, isVideo: true)
        let pairs = LivePhotoPairing(photos: [still, motion])
        XCTAssertEqual(pairs.motionByStillId[still.id]?.id, motion.id)
        XCTAssertEqual(pairs.attachMotion(to: still).liveMotionFileId, motion.id)
        XCTAssertEqual(items([still, motion]).map(\.cloudFileId), [still.id])
    }

    func testSameFilenameWithDifferentAppleIdentifiersStaysSeparate() throws {
        let still = try photo(id: "still", name: "IMG_0340.HEIC", identifier: identifier)
        let motion = try photo(
            id: "motion",
            name: "IMG_0340.MP4",
            identifier: "BE95F668-7FF5-4601-B5F0-E93E2C1D3773",
            isVideo: true
        )
        XCTAssertTrue(LivePhotoPairing(photos: [still, motion]).motionFileIds.isEmpty)
        XCTAssertEqual(items([still, motion]).count, 2)
    }

    func testAmbiguousStillAndLongVideoRemainSeparate() throws {
        let still = try photo(id: "still", name: "one.heic", identifier: identifier)
        let duplicate = try photo(id: "duplicate", name: "two.heic", identifier: identifier)
        let motion = try photo(id: "motion", name: "one.mp4", identifier: identifier, isVideo: true)
        XCTAssertTrue(LivePhotoPairing(photos: [still, duplicate, motion]).motionFileIds.isEmpty)
        XCTAssertEqual(items([still, duplicate, motion]).count, 3)

        let longVideo = try photo(id: "long", name: "one.mp4", identifier: identifier, isVideo: true, duration: 30)
        XCTAssertTrue(LivePhotoPairing(photos: [still, longVideo]).motionFileIds.isEmpty)
    }

    func testIdenticalIdentifierInDifferentLibraryScopesDoesNotPair() throws {
        let still = try photo(id: "still", name: "one.heic", identifier: identifier)
        var motion = try photo(id: "motion", name: "one.mov", identifier: identifier, isVideo: true)
        motion.libraryRootId = "another-root"
        XCTAssertTrue(LivePhotoPairing(photos: [still, motion]).motionFileIds.isEmpty)
    }

    @MainActor
    func testMapKeepsLivePhotoCompanionAndHidesItsSeparateVideoPoint() throws {
        var still = try photo(id: "still", name: "photo.heic", identifier: identifier)
        still.coordinate = MediaCoordinate(latitude: 48, longitude: 2)
        still.locationSource = "embedded"
        var motion = try photo(id: "motion", name: "photo.mov", identifier: identifier, isVideo: true)
        motion.coordinate = still.coordinate
        motion.locationSource = "embedded"

        let points = PhotoMapViewModel.makePoints(photos: [still, motion], localLocations: [])

        XCTAssertEqual(points.map(\.id), [still.id])
        XCTAssertEqual(points.first?.photo.liveMotionFileId, motion.id)
        XCTAssertEqual(points.first?.latitude, 48)
        XCTAssertEqual(points.first?.longitude, 2)
    }

    private func items(_ photos: [PhotoSnapshot]) -> [GalleryItem] {
        GalleryComposerImpl.merge(
            localAssets: [], cloudPhotos: photos, backupItems: [:], deletionItems: [:], uploadStates: [:]
        )
    }

    private func photo(
        id: String, name: String, identifier: String, isVideo: Bool = false, duration: Double = 2
    ) throws -> PhotoSnapshot {
        var photo = PhotoSnapshot(
            id: id,
            driveId: 7,
            localIdentifier: "",
            name: name,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            uploadedAt: Date(),
            mimeType: isVideo ? "video/mp4" : "image/heic",
            size: 100,
            isVideo: isVideo,
            duration: duration,
            albumIds: [],
            syncStatus: .synced,
            isFavorite: false
        )
        photo.libraryRootId = "root"
        photo.liveContentIdentifier = identifier
        var metadata = EmbeddedMediaMetadata()
        metadata.duration = isVideo ? duration : nil
        photo.embeddedMetadataJSON = try XCTUnwrap(String(data: JSONEncoder().encode(metadata), encoding: .utf8))
        return photo
    }
}
