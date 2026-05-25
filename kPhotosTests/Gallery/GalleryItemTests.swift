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

final class GalleryItemTests: XCTestCase {
    func testFromCloud_forcesSyncedAndCopiesCloudIds() {
        let photo = makePhotoSnapshot(fileId: "F1", driveId: 7, isVideo: true)
        let item = GalleryItem.fromCloud(photo)

        XCTAssertEqual(item.id, "F1")
        XCTAssertEqual(item.cloudFileId, "F1")
        XCTAssertEqual(item.cloudDriveId, 7)
        XCTAssertNil(item.localAssetIdentifier, "Une photo cloud n'a pas d'ancrage local")
        XCTAssertTrue(item.isVideo)
        XCTAssertEqual(item.syncState, .synced, "Toute photo d'album est par définition déjà sur kDrive")
    }
}

final class ViewerMediaTests: XCTestCase {
    func testCloudCase_exposesPrefixedIdAndCloudBacking() {
        let photo = makePhotoSnapshot(fileId: "F1", driveId: 1, isVideo: true)
        let media = ViewerMedia.cloud(photo)

        XCTAssertEqual(media.id, "cloud-F1")
        XCTAssertEqual(media.takenAt, photo.takenAt)
        XCTAssertTrue(media.isVideo)
        XCTAssertTrue(media.isCloudBacked)
    }

    func testLocalCase_exposesPrefixedIdAndNotCloudBacked() {
        let asset = LocalAssetSnapshot(localIdentifier: "L1",
                                       takenAt: Date(timeIntervalSince1970: 5000),
                                       isVideo: false)
        let media = ViewerMedia.local(asset)

        XCTAssertEqual(media.id, "local-L1")
        XCTAssertEqual(media.takenAt, asset.takenAt)
        XCTAssertFalse(media.isVideo)
        XCTAssertFalse(media.isCloudBacked, "Un asset purement local n'autorise pas les actions API")
    }
}

final class GallerySectionTests: XCTestCase {
    func testId_isZeroPaddedYearMonth() {
        XCTAssertEqual(GallerySection(year: 2024, month: 3, items: []).id, "2024-03")
        XCTAssertEqual(GallerySection(year: 2024, month: 11, items: []).id, "2024-11")
    }
}

final class LocalAssetSnapshotIdentityTests: XCTestCase {
    func testId_equalsLocalIdentifier() {
        let asset = LocalAssetSnapshot(localIdentifier: "L42", takenAt: Date(), isVideo: false)
        XCTAssertEqual(asset.id, "L42")
        XCTAssertEqual(asset.id, asset.localIdentifier)
    }
}

private func makePhotoSnapshot(fileId: String, driveId: Int, isVideo: Bool) -> PhotoSnapshot {
    PhotoSnapshot(
        id: fileId, driveId: driveId, localIdentifier: "", name: "\(fileId).jpg",
        takenAt: Date(timeIntervalSince1970: 1000), uploadedAt: Date(timeIntervalSince1970: 2000),
        mimeType: isVideo ? "video/quicktime" : "image/jpeg", size: 0, isVideo: isVideo,
        duration: 0, albumIds: [], syncStatus: .synced, isFavorite: false
    )
}
