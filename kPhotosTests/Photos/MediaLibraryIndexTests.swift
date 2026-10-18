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
import RealmSwift
import XCTest

final class MediaLibraryIndexTests: XCTestCase {
    func testOwnIndexRoundTripsAndRejectsWrongScopeAndGoogleSidecars() throws {
        var metadata = EmbeddedMediaMetadata()
        metadata.coordinate = MediaCoordinate(latitude: 48, longitude: 2)
        metadata.captureDate = Date(timeIntervalSince1970: 1_500_000_000)
        metadata.hasExplicitTimezone = true
        let index = MediaLibraryIndex(
            driveId: 7,
            rootId: "root",
            totalMedia: 3,
            pending: 1,
            failed: 1,
            records: [.init(fileId: "10", revision: "rev", metadata: metadata)]
        )
        let bytes = try index.encode()
        let decoded = try MediaLibraryIndex.decode(bytes, driveId: 7, rootId: "root")
        XCTAssertEqual(decoded.records[0].metadata, metadata)
        XCTAssertThrowsError(try MediaLibraryIndex.decode(bytes, driveId: 8, rootId: "root"))
        XCTAssertThrowsError(try MediaLibraryIndex.decode(bytes, driveId: 7, rootId: "other"))
        XCTAssertThrowsError(try MediaLibraryIndex.decode(
            Data(#"{"geoData":{"latitude":48,"longitude":2}}"#.utf8),
            driveId: 7,
            rootId: "root"
        ))
    }

    func testMalformedCountersAndDuplicateRecordsCannotBecomeAnIndex() throws {
        let record = MediaIndexRecord(fileId: "10", revision: "rev", metadata: .init())
        let duplicate = MediaLibraryIndex(
            driveId: 7,
            rootId: "root",
            totalMedia: 2,
            pending: 0,
            failed: 0,
            records: [record, record]
        )
        XCTAssertThrowsError(try duplicate.validate(driveId: 7, rootId: "root"))
        let oversized = MediaLibraryIndex(driveId: 7, rootId: "root", totalMedia: 1, pending: Int.max, failed: 0, records: [])
        XCTAssertThrowsError(try oversized.validate(driveId: 7, rootId: "root"))
    }

    func testDecodedCoordinatesAreValidatedBeforeAnyWrite() throws {
        let index = MediaLibraryIndex(
            driveId: 7,
            rootId: "root",
            totalMedia: 1,
            pending: 0,
            failed: 0,
            records: [.init(fileId: "10", revision: "rev", metadata: .init())]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: index.encode()) as? [String: Any])
        var records = try XCTUnwrap(json["records"] as? [[String: Any]])
        var metadata = try XCTUnwrap(records[0]["metadata"] as? [String: Any])
        metadata["coordinate"] = ["latitude": 999, "longitude": 2]
        records[0]["metadata"] = metadata; json["records"] = records
        XCTAssertThrowsError(try MediaLibraryIndex.decode(
            JSONSerialization.data(withJSONObject: json),
            driveId: 7,
            rootId: "root"
        ))
    }

    @MainActor
    func testPreparedIndexUpdatesOnlyMatchingOriginalRevisionsAndPreservesClientState() async throws {
        let config = Realm.Configuration(inMemoryIdentifier: UUID().uuidString, objectTypes: [Photo.self])
        let held = try holdRealm(config)
        try held.write {
            for id in ["10", "11", "12"] {
                let photo = Photo(); photo.fileId = id; photo.driveId = 7; photo.libraryRootId = "root"
                photo.remoteRevision = id == "11" ? "changed" : "rev"
                photo.isAvailable = true; photo.isFavorite = true; photo.albumIds.append("album")
                if id == "12" { photo.libraryRootId = "other" }
                held.add(photo)
            }
        }
        let manager = PhotoManagerImpl(realm: RealmAccessorImpl(configuration: config))
        var metadata = EmbeddedMediaMetadata(); metadata.coordinate = MediaCoordinate(latitude: 48, longitude: 2)
        let index = MediaLibraryIndex(
            driveId: 7,
            rootId: "root",
            totalMedia: 3,
            pending: 0,
            failed: 0,
            records: ["10", "11", "12"].map { .init(fileId: $0, revision: "rev", metadata: metadata) }
        )
        try await manager.applyMediaIndex(index)
        let correct = try XCTUnwrap(manager.photo(byFileId: "10"))
        XCTAssertEqual(correct.coordinate, metadata.coordinate)
        XCTAssertTrue(correct.isFavorite)
        XCTAssertEqual(correct.albumIds, ["album"])
        XCTAssertNil(try manager.photo(byFileId: "11")?.coordinate)
        XCTAssertNil(try manager.photo(byFileId: "12")?.coordinate)
        held.refresh(); XCTAssertEqual(held.objects(Photo.self).count, 3)
    }

    func testCatalogueRejectsStaleMetadataAndArchiveEntries() throws {
        let dto = try JSONDecoder().decode(
            RemoteFileDTO.self,
            from: Data(
                #"{"id":10,"name":"image.jpg","type":"file","mime_type":"image/jpeg","size":100,"last_modified_at":1}"#
                    .utf8
            )
        )
        var index = MediaLibraryIndex(
            driveId: 7,
            rootId: "root",
            totalMedia: 1,
            pending: 0,
            failed: 0,
            records: [.init(fileId: "10", revision: dto.revision, metadata: .init())]
        )
        index.catalogue = [.init(file: dto)]; index.availableFileIds = ["10"]
        index.availableRevisions = ["10": dto.revision]; index.listedAt = Date()
        XCTAssertNoThrow(try index.encode())
        index.records = [.init(fileId: "10", revision: "stale", metadata: .init())]
        XCTAssertThrowsError(try index.encode())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: MediaLibraryIndex(
            driveId: 7,
            rootId: "root",
            totalMedia: 1,
            pending: 1,
            failed: 0,
            records: []
        ).encode()) as? [String: Any])
        json["catalogue"] = [
            [
                "fileId": "10",
                "revision": dto.revision,
                "name": "archive.zip",
                "mimeType": "image/jpeg",
                "size": 100,
                "isVideo": false,
                "uploadedAt": "2026-01-01T00:00:00Z",
                "fallbackDate": "2026-01-01T00:00:00Z"
            ]
        ]
        json["availableFileIds"] = ["10"]; json["availableRevisions"] = ["10": dto.revision]; json["listedAt"] =
            "2026-01-01T00:00:00Z"
        XCTAssertThrowsError(try MediaLibraryIndex.decode(
            JSONSerialization.data(withJSONObject: json),
            driveId: 7,
            rootId: "root"
        ))
    }

    func testThumbnailPackReadIsRevisionSpecificAndCannotOverwriteExistingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data([1, 2, 3])
        try ThumbnailPack.create(at: url, images: [("id", "rev", bytes)])
        XCTAssertEqual(try ThumbnailPack.imageData(at: url, fileId: "id", revision: "rev"), bytes)
        XCTAssertNil(try ThumbnailPack.imageData(at: url, fileId: "id", revision: "new"))
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try ThumbnailPack.create(at: url, images: [("id", "new", Data([4]))]))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try ThumbnailPack.imageData(at: url, fileId: "id", revision: "rev"))
    }

    private func holdRealm(_ configuration: Realm.Configuration) throws -> Realm { try Realm(configuration: configuration) }
}
