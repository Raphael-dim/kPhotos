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

public extension PhotoApiFetcher {
    /// Only the explicitly named kPhotos cache is considered, never arbitrary JSON or Google metadata.
    func mediaIndex(driveId: Int, rootId: String) async throws -> (String, MediaLibraryIndex)? {
        func children(_ folder: String) async throws -> [RemoteFileDTO] {
            var files: [RemoteFileDTO] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                let page = try await listFolder(driveId: driveId, folderId: folder, cursor: cursor, limit: 100)
                files += page.items
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted { throw PhotoAPIError.invalidResponse }
            } while cursor != nil
            return files
        }
        let roots = try await children(rootId)
        guard let folder = roots.first(where: { $0.isDirectory && $0.name == MediaLibraryIndex.folderName }) else { return nil }
        let candidates = try await children(folder.id).filter {
            !$0.isDirectory && $0.status == "ok" && $0.name.hasPrefix("index-") && $0.name.hasSuffix(".json")
                && $0.size > 0 && $0.size <= 32 * 1024 * 1024
        }
        .sorted { $0.lastModifiedAt == $1.lastModifiedAt ? $0.name > $1.name : $0.lastModifiedAt > $1.lastModifiedAt }
        guard let file = candidates.first else { return nil }
        let url = try await signedOriginalURL(driveId: driveId, fileId: file.id, priority: 0)
        let data = try await BoundedMediaRead(maximum: 32 * 1024 * 1024).read(url: url)
        let index = try MediaLibraryIndex.decode(data, driveId: driveId, rootId: rootId)
        guard index.cacheFolderId == nil || index.cacheFolderId == folder.id else { throw PhotoAPIError.invalidResponse }
        return (file.id + ":" + file.revision, index)
    }
}
