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

import Alamofire
import CryptoKit
import Foundation

public struct MediaIndexUploadState: Codable, Sendable {
    public let fileId: String
    public let folderId: String
    public let name: String
    public let sha256: String
    public var fingerprint: String
}

public extension PhotoApiFetcher {
    /// Updates only our verified derivative cache. Originals and arbitrary existing JSON files cannot be overwritten.
    func saveMediaIndex(
        _ index: MediaLibraryIndex,
        name: String,
        previous: MediaIndexUploadState?,
        clientToken: String
    ) async throws -> MediaIndexUploadState {
        guard index.rootId != "1", name.hasPrefix("index-ios-"),
              name.hasSuffix(".json") else { throw PhotoAPIError.invalidResponse }
        let folderId = try await mediaIndexCacheFolder(driveId: index.driveId, rootId: index.rootId)
        guard folderId != "1" else { throw PhotoAPIError.invalidResponse }
        var exported = index; exported.cacheFolderId = folderId
        let bytes = try exported.encode()
        if let previous {
            guard previous.folderId == folderId, previous.name == name else { throw PhotoAPIError.invalidResponse }
            let detail = try await fileInfo(driveId: index.driveId, fileId: previous.fileId)
            guard detail.name == name, detail.parentId == folderId else { throw PhotoAPIError.invalidResponse }
            let url = try await signedOriginalURL(driveId: index.driveId, fileId: previous.fileId, priority: 0)
            let prior = try await BoundedMediaRead(maximum: 32 * 1024 * 1024, configuration: binaryReadConfiguration)
                .read(url: url)
            if prior == bytes {
                return MediaIndexUploadState(
                    fileId: previous.fileId,
                    folderId: folderId,
                    name: name,
                    sha256: Self.indexHash(bytes),
                    fingerprint: ""
                )
            }
            guard Self.indexHash(prior) == previous.sha256 else { throw PhotoAPIError.invalidResponse }
        }

        let uploaded: RemoteFileDTO = try await performWithRetry {
            let endpoint = Endpoint.upload(
                driveId: index.driveId,
                directoryId: folderId,
                fileName: name,
                totalSize: bytes.count,
                createdAt: Int(index.generatedAt.timeIntervalSince1970),
                clientToken: clientToken,
                conflict: previous == nil ? "error" : "version"
            )
            try await self.waitForRequest(priority: 0)
            let response = await self.session.upload(
                bytes,
                to: endpoint.url,
                method: .post,
                headers: ["Content-Type": "application/octet-stream"]
            )
            .validate()
            .serializingDecodable(InfomaniakResponse<RemoteFileDTO>.self, decoder: self.decoder)
            .response
            try Task.checkCancellation()
            if let result = response.value { return result.data }
            if let error = response.error { throw Self.mapAFError(error, statusCode: response.response?.statusCode) }
            throw PhotoAPIError.invalidResponse
        }
        let url = try await signedOriginalURL(driveId: index.driveId, fileId: uploaded.id, priority: 0)
        let verified = try await BoundedMediaRead(maximum: 32 * 1024 * 1024, configuration: binaryReadConfiguration)
            .read(url: url)
        guard verified == bytes else { throw PhotoAPIError.invalidResponse }
        return MediaIndexUploadState(
            fileId: uploaded.id,
            folderId: folderId,
            name: name,
            sha256: Self.indexHash(bytes),
            fingerprint: ""
        )
    }

    private func mediaIndexCacheFolder(driveId: Int, rootId: String) async throws -> String {
        var folders: [RemoteFileDTO] = []; var cursor: String?; var seen = Set<String>()
        repeat {
            let page = try await listFolder(driveId: driveId, folderId: rootId, cursor: cursor, limit: 100)
            folders += page.items.filter { $0.isDirectory && $0.name == MediaLibraryIndex.folderName }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw PhotoAPIError.invalidResponse }
        } while cursor != nil
        guard folders.count <= 1 else {
            throw PhotoAPIError.invalidResponse
        }
        if let folder = folders.first { return folder.id }
        return try await createDirectory(
            driveId: driveId,
            name: MediaLibraryIndex.folderName,
            parentId: rootId
        ).id
    }

    private static func indexHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
