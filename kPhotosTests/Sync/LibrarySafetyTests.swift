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

import Combine
import Foundation
@testable import kPhotosCore
import RealmSwift
import XCTest

@MainActor
final class LibrarySafetyTests: XCTestCase {
    func testNestedLibraryPaginationExcludesArchivesAndTrash() async throws {
        let api = LibraryTestAPI()
        api.pages = [
            "root:": FilePage(items: [
                file("prep", type: "dir"),
                file("raw", name: "Google Takout", type: "dir"),
                file("trash", name: "03_A_examiner", type: "dir")
            ], nextCursor: "two"),
            "root:two": FilePage(items: [file("zip", name: "archive.zip", mime: "application/zip")], nextCursor: nil),
            "prep:": FilePage(items: [file("year", type: "dir")], nextCursor: nil),
            "year:": FilePage(items: [file("photo"), file("json", name: "data.json", mime: "application/json")], nextCursor: nil)
        ]
        let result = try await LibraryScanner(api: api).scan(driveId: 7, rootId: "root")
        XCTAssertEqual(result.photos.map(\.id), ["photo"])
        XCTAssertEqual(result.photos.first?.libraryRootId, "root")
        XCTAssertFalse(api.listingRequests.contains("trash:"))
        XCTAssertFalse(api.listingRequests.contains("raw:"))
    }

    func testMissingPageFailsInsteadOfReturningPartialLibrary() async throws {
        let api = LibraryTestAPI()
        api.pages["root:"] = FilePage(items: [file("photo")], nextCursor: "missing")
        do { _ = try await LibraryScanner(api: api).scan(driveId: 7, rootId: "root"); XCTFail("Must fail") } catch {
            XCTAssertEqual(error as? PhotoAPIError, .notFound)
        }
    }

    func testRepeatedCursorCannotLoopForever() async throws {
        let api = LibraryTestAPI()
        api.pages["root:"] = FilePage(items: [], nextCursor: "repeat")
        api.pages["root:repeat"] = FilePage(items: [], nextCursor: "repeat")
        do { _ = try await LibraryScanner(api: api).scan(driveId: 7, rootId: "root"); XCTFail("Must fail") } catch {
            XCTAssertEqual(error as? PhotoAPIError, .invalidResponse)
        }
    }

    func testPreparedLibraryNeverOpensMetadataPackagesOrJournals() async throws {
        let api = LibraryTestAPI()
        api.pages = [
            "root:": FilePage(items: [file("prep", name: "Preparation", type: "dir")], nextCursor: nil),
            "prep:": FilePage(items: [
                file("media", name: "02_Phototheque", type: "dir"),
                file("package", name: "05_Paquet_kDrive_compact", type: "dir"),
                file("journal", name: "04_Journaux", type: "dir")
            ], nextCursor: nil),
            "media:": FilePage(items: [file("google"), file("embedded"), file("fallback")], nextCursor: nil),
            "package:": FilePage(items: [file("csv", name: "CATALOGUE_MEDIA_PORTABLE.csv", mime: "text/csv")], nextCursor: nil),
            "journal:": FilePage(items: [
                file("plan", name: "phototheque_plan.jsonl", mime: "application/json"),
                file("exif", name: "embedded_dates.jsonl", mime: "application/json")
            ], nextCursor: nil)
        ]
        api.downloads["csv"] = Data("chemin_relatif,date_google_utc\n02_Phototheque/google.jpg,2014-12-31T23:21:02Z\n".utf8)
        api.downloads["plan"] = Data("{\"source_path\":\"old\",\"destination\":\"02_Phototheque/embedded.jpg\"}".utf8)
        api.downloads["exif"] = try JSONSerialization.data(withJSONObject: [
            "path": "old",
            "date_tag": "DateTimeOriginal",
            "embedded_date": "2026:09:02 15:15:35",
            "offset_time_original": "+01:00"
        ])
        let result = try await LibraryScanner(api: api).scan(driveId: 7, rootId: "root")
        let photos = Dictionary(uniqueKeysWithValues: result.photos.map { ($0.id, $0) })
        XCTAssertEqual(photos["google"]?.captureDateSource, "kdrive")
        XCTAssertEqual(photos["embedded"]?.captureDateSource, "kdrive")
        XCTAssertFalse(api.listingRequests.contains("package:"))
        XCTAssertFalse(api.listingRequests.contains("journal:"))
        XCTAssertTrue(api.downloadRequests.isEmpty)
        XCTAssertFalse(try XCTUnwrap(photos["fallback"]).hasReliableCaptureDate)
        XCTAssertEqual(result.photos.count, 3)
    }

    func testMediaFilterAndDatesNeverPreferUploadOverAvailableModificationTime() throws {
        XCTAssertFalse(file("zip", name: "photo.jpg.zip", mime: "application/zip").isMedia)
        XCTAssertTrue(file("mov", name: "photo.MOV", mime: "application/octet-stream").isVideoMedia)
        var incomplete = file("photo"); incomplete.status = "uploading"
        XCTAssertFalse(incomplete.isMedia)
        let dto = RemoteFileDTO(
            id: "1",
            name: "old.jpg",
            createdAt: 0,
            addedAt: 999,
            lastModifiedAt: 100,
            mimeType: "image/jpeg",
            size: 3,
            hasThumbnail: false
        )
        XCTAssertEqual(dto.bestTakenAt, 100)
    }

    func testCompleteScanHidesStaleCacheWithoutDeletingIt() async throws {
        let accessor = RealmAccessorImpl(configuration: .inMemoryKPhotos)
        let keeper = try keepRealm(accessor.configuration)
        let manager = PhotoManagerImpl(realm: accessor)
        var old = PhotoSyncEngine.makeSnapshot(from: file("old"), driveId: 7)
        old.libraryRootId = "root"
        try await manager.upsert(old)
        try await manager.commitListing([], driveId: 7, folderId: "root", fileIds: [], revisions: [:])
        let retained = try XCTUnwrap(manager.photo(byFileId: "old"))
        XCTAssertFalse(retained.isAvailable)
        XCTAssertEqual(keeper.objects(Photo.self).count, 1)
    }

    func testMissingCompanionInvalidatesBackupWithoutDiscardingMetadata() async throws {
        let accessor = RealmAccessorImpl(configuration: .inMemoryKPhotos)
        let keeper = try keepRealm(accessor.configuration)
        let manager = PhotoManagerImpl(realm: accessor)
        var saved = PhotoSyncEngine.makeSnapshot(from: file("image"), driveId: 7)
        saved.libraryRootId = "root"; saved.backupComplete = true; saved.resourceFileIds = ["image", "motion", "metadata"]
        try await manager.upsert(saved)
        try await manager.commitListing([saved], driveId: 7, folderId: "root", fileIds: ["image", "metadata"], revisions: [:])
        let retained = try XCTUnwrap(manager.photo(byFileId: "image"))
        XCTAssertFalse(retained.backupComplete)
        XCTAssertEqual(retained.resourceFileIds, ["image", "motion", "metadata"])
        _ = keeper
    }

    func testExactSelectedFolderIsResolvedWithoutLookingUpItsName() async throws {
        let accessor = RealmAccessorImpl(configuration: .inMemoryKPhotos)
        let keeper = try keepRealm(accessor.configuration)
        try await accessor.write { realm in
            let drive = Drive(); drive.id = 7; drive.isSelected = true; realm.add(drive)
        }
        let api = LibraryTestAPI(); api.pages["nested:"] = FilePage(items: [], nextCursor: nil)
        let manager = DriveManagerImpl(realm: accessor, api: api)
        try await manager.selectRootFolder(id: "nested")
        let resolved = try await manager.existingRootFolder(folderName: "Same name elsewhere")
        XCTAssertEqual(resolved, "nested")
        XCTAssertEqual(try manager.selectedDrive()?.rootFolderId, "nested")
        _ = keeper
    }

    func testIdenticalMacUploadIsReusedWithoutSendingAnotherCopy() async throws {
        let api = LibraryTestAPI(); api.downloads["mac"] = Data("original".utf8)
        let resource = try localResource("original")
        defer { try? FileManager.default.removeItem(at: resource.fileURL) }
        var candidate = PhotoSyncEngine.makeSnapshot(from: file("mac", size: 8), driveId: 7)
        candidate.libraryRootId = "root"
        let result = try await ResourceBackup(api: api).findOrUpload(
            resource: resource,
            identity: .init(date: Date(), token: "test", localIdentifier: "local-photo"),
            driveId: 7,
            folderId: "root",
            candidates: [candidate]
        )
        XCTAssertEqual(result.0.id, "mac"); XCTAssertEqual(api.uploads, 0)
    }

    func testExistingDestinationFileIsVerifiedWithoutFullLibraryScan() async throws {
        let api = LibraryTestAPI()
        api.pages["root:"] = FilePage(items: [file("existing", name: "test.jpg", size: 8)], nextCursor: nil)
        api.downloads["existing"] = Data("original".utf8)
        let resource = try localResource("original")
        defer { try? FileManager.default.removeItem(at: resource.fileURL) }

        let result = try await ResourceBackup(api: api).findOrUpload(
            resource: resource,
            identity: .init(date: Date(), token: "retry", localIdentifier: "local-photo"),
            driveId: 7,
            folderId: "root",
            candidates: []
        )

        XCTAssertEqual(result.0.id, "existing")
        XCTAssertEqual(api.uploads, 0)
        XCTAssertEqual(api.listingRequests, ["root:"])
    }

    func testBatchReconcilePreservesKnownItemsAndQueuesOnlyMissingAssets() async throws {
        let accessor = RealmAccessorImpl(configuration: .inMemoryKPhotos)
        let keeper = try keepRealm(accessor.configuration)
        let manager = PhotoManagerImpl(realm: accessor)
        let date = Date(timeIntervalSince1970: 1000)
        for identifier in ["synced", "stale", "skipped"] {
            try await manager.enqueueIfAbsent(localIdentifier: identifier, creationDate: date, isVideo: false)
        }
        try await manager.markCompleted(localIdentifier: "synced")
        try await manager.markCompleted(localIdentifier: "stale")
        try await manager.markSkipped(localIdentifier: "skipped", reason: "User skipped")
        let staleToken = try XCTUnwrap(manager.item(localIdentifier: "stale")?.clientToken)

        let assets = ["synced", "stale", "skipped", "new"].map {
            LocalAssetSnapshot(localIdentifier: $0, takenAt: date, isVideo: $0 == "new")
        }
        try await manager.reconcile(localAssets: assets, syncedIdentifiers: ["synced"])
        try await manager.reconcile(localAssets: assets, syncedIdentifiers: ["synced"])

        XCTAssertEqual(try manager.allItems().count, 4)
        XCTAssertEqual(try manager.item(localIdentifier: "synced")?.state, .completed)
        XCTAssertEqual(try manager.item(localIdentifier: "stale")?.state, .queued)
        XCTAssertEqual(try manager.item(localIdentifier: "stale")?.clientToken, staleToken)
        XCTAssertEqual(try manager.item(localIdentifier: "skipped")?.state, .skipped)
        XCTAssertEqual(try manager.item(localIdentifier: "new")?.state, .queued)
        XCTAssertEqual(try manager.item(localIdentifier: "new")?.isVideo, true)
        _ = keeper
    }

    func testIdenticalBytesLinkedToAnotherLocalAssetGetTheirOwnCloudFile() async throws {
        let api = LibraryTestAPI()
        api.downloads["first"] = Data("original".utf8)
        api.pages["root:"] = FilePage(items: [], nextCursor: nil)
        let resource = try localResource("original")
        defer { try? FileManager.default.removeItem(at: resource.fileURL) }
        var candidate = PhotoSnapshot(
            id: "first",
            driveId: 7,
            localIdentifier: "first-local",
            name: "first.jpg",
            takenAt: Date(),
            uploadedAt: Date(),
            mimeType: "image/jpeg",
            size: 8,
            isVideo: false,
            duration: 0,
            albumIds: [],
            syncStatus: .synced,
            isFavorite: false
        )
        candidate.libraryRootId = "root"

        let result = try await ResourceBackup(api: api).findOrUpload(
            resource: resource,
            identity: .init(date: Date(), token: "second-token", localIdentifier: "second-local"),
            driveId: 7,
            folderId: "root",
            candidates: [candidate]
        )

        XCTAssertEqual(result.0.id, "upload-1")
        XCTAssertEqual(api.uploads, 1)
        XCTAssertFalse(api.downloadRequests.contains("first"))
    }

    func testSameSizeDifferentBytesDoesNotCountAsDuplicate() async throws {
        let api = LibraryTestAPI(); api.downloads["mac"] = Data("different".utf8)
        api.pages["root:"] = FilePage(items: [], nextCursor: nil)
        let resource = try localResource("original!")
        defer { try? FileManager.default.removeItem(at: resource.fileURL) }
        let candidate = PhotoSyncEngine.makeSnapshot(from: file("mac", size: 9), driveId: 7)
        _ = try await ResourceBackup(api: api).findOrUpload(
            resource: resource,
            identity: .init(date: Date(), token: "test", localIdentifier: "local-photo"),
            driveId: 7,
            folderId: "root",
            candidates: [candidate]
        )
        XCTAssertEqual(api.uploads, 1)
    }

    func testCorruptUploadedContentCannotBecomeSuccessfulBackup() async throws {
        let api = LibraryTestAPI(); api.corruptUploads = true
        api.pages["root:"] = FilePage(items: [], nextCursor: nil)
        let resource = try localResource("original")
        defer { try? FileManager.default.removeItem(at: resource.fileURL) }
        do {
            _ = try await ResourceBackup(api: api).findOrUpload(
                resource: resource,
                identity: .init(date: Date(), token: "test", localIdentifier: "local-photo"),
                driveId: 7,
                folderId: "root",
                candidates: []
            )
            XCTFail("Corrupt upload must fail")
        } catch { XCTAssertTrue(error is BackupSafetyError) }
    }

    func testUploadHostCannotExfiltrateToken() throws {
        XCTAssertTrue(try PhotoApiFetcher.trustedUploadHost(XCTUnwrap(URL(string: "https://upload.kdrive.infomaniak.com"))))
        for url in [
            "https://infomaniak.com.attacker.test",
            "http://upload.infomaniak.com",
            "https://user@upload.infomaniak.com"
        ] {
            XCTAssertFalse(try PhotoApiFetcher.trustedUploadHost(XCTUnwrap(URL(string: url))))
        }
    }

    private func keepRealm(_ configuration: Realm.Configuration) throws -> Realm {
        try Realm(configuration: configuration)
    }

    private func localResource(_ text: String) throws -> ExportedResource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data(text.utf8).write(to: url)
        return ExportedResource(
            fileURL: url,
            fileName: "test.jpg",
            mimeType: "image/jpeg",
            resourceType: 1,
            originalFilename: "test.jpg"
        )
    }

    private func file(
        _ id: String,
        name: String? = nil,
        type: String = "file",
        mime: String = "image/jpeg",
        size: Int64 = 3
    ) -> RemoteFileDTO {
        RemoteFileDTO(
            id: id,
            name: name ?? id + ".jpg",
            type: type,
            createdAt: 100,
            lastModifiedAt: 100,
            mimeType: mime,
            size: size,
            hasThumbnail: true
        )
    }
}
