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
        source: UploadSource,
        createdAt: Date,
        clientToken: String
    ) async throws -> RemoteFileDTO {
        let fileURL = source.fileURL
        let fileName = source.fileName
        let mimeType = source.mimeType

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
    func allDrives() throws -> [DriveSnapshot] { try [XCTUnwrap(selectedDrive())] }
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
