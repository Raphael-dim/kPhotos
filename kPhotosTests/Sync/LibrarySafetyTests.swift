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
        api
            .downloads["exif"] = Data(
                "{\"path\":\"old\",\"date_tag\":\"DateTimeOriginal\",\"embedded_date\":\"2026:09:02 15:15:35\",\"offset_time_original\":\"+01:00\"}"
                    .utf8
            )
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

    func testMediaFilterAndDatesNeverPreferUploadOverAvailableModificationTime() {
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

    private func keepRealm(_ configuration: Realm.Configuration) throws -> Realm {
        try Realm(configuration: configuration)
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

class LibraryTestAPI: PhotoApiFetching {
    var pages: [String: FilePage] = [:]
    var downloads: [String: Data] = [:]
    var downloadRequests: [String] = []
    var uploads = 0
    var corruptUploads = false
    var listingRequests: [String] = []
    func deleteFile(driveId: Int, fileId: String) async throws { XCTFail("No remote deletion is allowed") }
    // Méthodes non utilisées par les tests de suppression.
    func listFolder(driveId: Int, folderId: String, cursor: String?, limit: Int) async throws -> FilePage {
        let key = folderId + ":" + (cursor ?? "")
        listingRequests.append(key)
        guard let page = pages[key] else { throw PhotoAPIError.notFound }
        return page
    }

    func upload(
        driveId: Int,
        folderId: String,
        fileURL: URL,
        fileName: String,
        createdAt: Date,
        mimeType: String,
        clientToken: String
    ) async throws -> RemoteFileDTO {
        uploads += 1
        let data = try Data(contentsOf: fileURL)
        let id = "upload-\(uploads)"
        downloads[id] = corruptUploads ? Data("bad".utf8) : data
        return RemoteFileDTO(
            id: id,
            name: fileName,
            createdAt: 1,
            lastModifiedAt: 1,
            mimeType: mimeType,
            size: Int64(data.count),
            hasThumbnail: true
        )
    }

    func createDirectory(driveId: Int, name: String, parentId: String) async throws -> RemoteDirectoryDTO {
        throw PhotoAPIError.invalidResponse
    }

    func listDrives() async throws -> [RemoteDriveDTO] { [] }
    func listCategories(driveId: Int) async throws -> [RemoteCategoryDTO] { [] }
    func createCategory(driveId: Int, name: String, color: String?) async throws -> RemoteCategoryDTO {
        throw PhotoAPIError.invalidResponse
    }

    func updateCategory(driveId: Int, categoryId: Int, name: String?, color: String?) async throws -> RemoteCategoryDTO {
        throw PhotoAPIError.invalidResponse
    }

    func deleteCategory(driveId: Int, categoryId: Int) async throws {}
    func addCategoryToFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws {}
    func removeCategoryFromFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws {}
    func listCategoryFiles(driveId: Int, categoryId: Int, cursor: String?, limit: Int) async throws -> FilePage {
        throw PhotoAPIError.invalidResponse
    }

    func saveMediaIndex(
        _ index: MediaLibraryIndex,
        name: String,
        previous: MediaIndexUploadState?,
        clientToken: String
    ) async throws -> MediaIndexUploadState {
        throw PhotoAPIError.invalidResponse
    }

    func originalMetadata(driveId: Int, fileId: String, isVideo: Bool) async throws -> EmbeddedMediaMetadata {
        throw PhotoAPIError.invalidResponse
    }

    func thumbnailData(driveId: Int, fileId: String) async throws -> Data { Data() }
    func previewData(driveId: Int, fileId: String, width: Int?, height: Int?, quality: Int?) async throws -> Data {
        Data()
    }

    func downloadFile(driveId: Int, fileId: String) async throws -> URL {
        downloadRequests.append(fileId)
        guard let data = downloads[fileId] else { throw PhotoAPIError.notFound }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    func playbackURL(driveId: Int, fileId: String) async throws -> URL { throw PhotoAPIError.invalidResponse }
    func downloadURL(driveId: Int, fileId: String) -> URL {
        Endpoint.download(driveId: driveId, fileId: fileId).url
    }

    func previewURL(driveId: Int, fileId: String) -> URL {
        Endpoint.preview(driveId: driveId, fileId: fileId).url
    }

    func fileInfo(driveId: Int, fileId: String) async throws -> RemoteFileDetailDTO {
        throw PhotoAPIError.invalidResponse
    }
}

final class CloudLibraryRefreshTests: XCTestCase {
    func testFolderChangedDuringScanLoadsNewSelection() async throws {
        let drives = RefreshTestDrives()
        let sync = RefreshTestSync()
        sync.onRefresh = { root in if root == "old" { drives.root = "new" } }
        let result = try await CloudLibraryRefresh(
            drives: drives,
            settings: RefreshTestSettings(),
            sync: sync,
            photos: RefreshTestPhotos()
        ).load()
        XCTAssertEqual(sync.requests, ["old", "new"])
        XCTAssertEqual(result.map(\.fileId), ["new-photo"])
    }

    func testObsoleteFolderFailureDoesNotBlockNewSelection() async throws {
        let drives = RefreshTestDrives()
        let sync = RefreshTestSync()
        sync.onRefresh = { root in
            if root == "old" { drives.root = "new"; throw PhotoAPIError.notFound }
        }
        let result = try await CloudLibraryRefresh(
            drives: drives,
            settings: RefreshTestSettings(),
            sync: sync,
            photos: RefreshTestPhotos()
        ).load()
        XCTAssertEqual(sync.requests, ["old", "new"])
        XCTAssertEqual(result.map(\.fileId), ["new-photo"])
    }

    func testCurrentFolderFailureRemainsVisibleRatherThanRetryingForever() async throws {
        let sync = RefreshTestSync()
        sync.onRefresh = { _ in throw PhotoAPIError.notFound }
        do {
            _ = try await CloudLibraryRefresh(
                drives: RefreshTestDrives(),
                settings: RefreshTestSettings(),
                sync: sync,
                photos: RefreshTestPhotos()
            ).load()
            XCTFail("Must report current-folder failure")
        } catch { XCTAssertEqual(error as? PhotoAPIError, .notFound) }
        XCTAssertEqual(sync.requests, ["old"])
    }
}

private final class RefreshTestDrives: DriveManaging {
    var root = "old"
    func selectedDrive() throws -> DriveSnapshot? {
        DriveSnapshot(
            id: 7,
            name: "Test",
            size: 0,
            usedSize: 0,
            role: "",
            isInMaintenance: false,
            isSelected: true,
            privateSpaceId: "private",
            rootFolderId: root
        )
    }

    func refreshFromServer() async throws -> [DriveSnapshot] { try allDrives() }
    func allDrives() throws -> [DriveSnapshot] { try [selectedDrive()!] }
    func selectDrive(id: Int) async throws {}
    func selectRootFolder(id: String) async throws { root = id }
    func ensurePrivateSpace() async throws -> String { "private" }
    func ensureRootFolder(folderName: String) async throws -> String { root }
    func existingRootFolder(folderName: String) async throws -> String { root }
    func resetCachedRootFolders() async throws {}
}

private final class RefreshTestSettings: SyncSettingsReading {
    func current() throws -> SyncSettingsSnapshot { .defaults }
    var publisher: AnyPublisher<SyncSettingsSnapshot, Never> { Just(.defaults).eraseToAnyPublisher() }
}

private final class RefreshTestSync: PhotoSyncing {
    var requests: [String] = []
    var onRefresh: ((String) throws -> Void)?
    func refreshFolder(driveId: Int, folderId: String) async throws {
        requests.append(folderId)
        try onRefresh?(folderId)
    }

    func reconcile() async throws {}
    func runFullSync(
        driveId: Int,
        folderId: String,
        maxItems: Int?,
        onProgress: @MainActor @escaping (SyncProgress) -> Void
    ) async throws { XCTFail("Must never upload") }
}

private final class RefreshTestPhotos: PhotoReading {
    func allPhotos() throws -> [PhotoSnapshot] {
        ["old", "new"].map { root in
            var photo = PhotoSnapshot(
                id: root + "-photo",
                driveId: 7,
                localIdentifier: "",
                name: "photo.jpg",
                takenAt: Date(),
                uploadedAt: Date(),
                mimeType: "image/jpeg",
                size: 1,
                isVideo: false,
                duration: 0,
                albumIds: [],
                syncStatus: .synced,
                isFavorite: false
            )
            photo.libraryRootId = root
            return photo
        }
    }

    func photo(byFileId fileId: String) throws -> PhotoSnapshot? { try allPhotos().first { $0.fileId == fileId } }
    func photo(byLocalIdentifier localIdentifier: String) throws -> PhotoSnapshot? { nil }
}
