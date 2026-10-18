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

@MainActor
final class MediaIndexPublisherTests: XCTestCase {
    func testUnchangedIndexDoesNotUploadAgainAndFailedUploadReusesToken() async throws {
        let config = Realm.Configuration(inMemoryIdentifier: UUID().uuidString, objectTypes: [Photo.self])
        let realm = try holdRealm(config)
        try realm.write {
            let photo = Photo(); photo.fileId = "id"; photo.driveId = 7; photo.libraryRootId = "root"
            photo.name = "image.jpg"; photo.mimeType = "image/jpeg"; photo.remoteRevision = "v1"
            photo.embeddedMetadataRevision = "v1"
            var metadata = EmbeddedMediaMetadata(); metadata.partialRead = false; metadata.readerVersion = 2
            photo.embeddedMetadataJSON = try String(decoding: JSONEncoder().encode(metadata), as: UTF8.self)
            realm.add(photo)
        }
        let reader = PhotoManagerImpl(realm: RealmAccessorImpl(configuration: config))
        let api = IndexUploadAPI()
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let publisher = MediaIndexPublisher(api: api, reader: reader, defaults: defaults)
        do { try await publisher.publishIfNeeded(driveId: 7, rootId: "root"); XCTFail("Synthetic interruption must fail")
        } catch {
            XCTAssertEqual(error as? PhotoAPIError, .network(underlying: "synthetic"))
        }
        api.shouldFail = false
        try await publisher.publishIfNeeded(driveId: 7, rootId: "root")
        XCTAssertEqual(api.tokens.count, 2); XCTAssertEqual(api.tokens[0], api.tokens[1])
        XCTAssertEqual(api.dates[0], api.dates[1])
        try await publisher.publishIfNeeded(driveId: 7, rootId: "root")
        XCTAssertEqual(api.tokens.count, 2)
        XCTAssertEqual(api.lastIndex?.records.count, 1)
        XCTAssertEqual(api.lastIndex?.catalogue?.count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "mediaIndexUpload.7.root.history")?.count, 1)
        realm.refresh(); XCTAssertEqual(realm.objects(Photo.self).count, 1)
    }
}

private final class IndexUploadAPI: LibraryTestAPI {
    var tokens: [String] = []; var dates: [Date] = []; var lastIndex: MediaLibraryIndex?
    var shouldFail = true
    override func saveMediaIndex(
        _ index: MediaLibraryIndex,
        name: String,
        previous: MediaIndexUploadState?,
        clientToken: String
    ) async throws -> MediaIndexUploadState {
        try index.validate(driveId: 7, rootId: "root")
        tokens.append(clientToken); dates.append(index.generatedAt); lastIndex = index
        if shouldFail { throw PhotoAPIError.network(underlying: "synthetic") }
        return MediaIndexUploadState(
            fileId: "cache",
            folderId: "folder",
            name: name,
            sha256: String(repeating: "a", count: 64),
            fingerprint: ""
        )
    }
}

private func holdRealm(_ config: Realm.Configuration) throws -> Realm { try Realm(configuration: config) }
