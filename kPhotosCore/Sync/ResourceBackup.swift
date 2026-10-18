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

final class ResourceBackup {
    let api: PhotoApiFetching
    private var directoryFiles: [String: [RemoteFileDTO]] = [:]
    init(api: PhotoApiFetching) { self.api = api }

    private func files(driveId: Int, folderId: String) async throws -> [RemoteFileDTO] {
        if let cached = directoryFiles[folderId] { return cached }
        var all: [RemoteFileDTO] = []
        var cursor: String?
        var cursors = Set<String>()
        repeat {
            let page = try await api.listFolder(driveId: driveId, folderId: folderId, cursor: cursor, limit: 100)
            all.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw PhotoAPIError.invalidResponse }
        } while cursor != nil
        directoryFiles[folderId] = all
        return all
    }

    func destination(driveId: Int, rootId: String, date: Date) async throws -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { throw BackupSafetyError.incomplete }
        var parent = rootId
        for name in [String(format: "%04d", year), String(format: "%02d", month)] {
            let listing = try await files(driveId: driveId, folderId: parent)
            if let existing = listing.first(where: { $0.isDirectory && $0.name == name }) {
                parent = existing.id
            } else {
                let created = try await api.createDirectory(driveId: driveId, name: name, parentId: parent)
                directoryFiles[parent] = nil
                parent = created.id
            }
        }
        return parent
    }

    func findOrUpload(
        resource: ExportedResource,
        date: Date,
        token: String,
        localIdentifier: String,
        driveId: Int,
        folderId: String,
        candidates: [PhotoSnapshot]
    ) async throws -> (RemoteFileDTO, String) {
        let size = try FileManager.default.attributesOfItem(atPath: resource.fileURL.path)[.size] as? Int64 ?? 0
        let hash = try MediaIntegrity.sha256(file: resource.fileURL)
        let reusable = candidates.filter {
            $0.size == size && $0.isAvailable
                && ($0.localIdentifier.isEmpty || $0.localIdentifier == localIdentifier)
        }
        for candidate in reusable {
            // A cloud original may be linked once. Reusing an original already linked
            // to another PHAsset would overwrite its Realm row (keyed by file ID).
            // A cached fingerprint is only a hint: verify current remote bytes before claiming a backup.
            if !candidate.contentSHA256.isEmpty, candidate.contentSHA256 != hash { continue }
            let matches = try await verify(fileId: candidate.id, driveId: driveId, expectedHash: hash)
            if matches {
                var dto = RemoteFileDTO(
                    id: candidate.id,
                    name: candidate.name,
                    createdAt: Int(date.timeIntervalSince1970),
                    lastModifiedAt: 0,
                    mimeType: candidate.mimeType,
                    size: candidate.size,
                    hasThumbnail: false
                )
                dto.revision = candidate.remoteRevision
                return (dto, hash)
            }
        }
        // Inspect the destination as well: recovers an upload whose response was lost, including companions/JSON.
        let destinationFiles = try await files(driveId: driveId, folderId: folderId)
        for file in destinationFiles where file.name == resource.fileName && !file.isDirectory
            && file.status != "uploading" {
            guard file.size == size, try await verify(fileId: file.id, driveId: driveId, expectedHash: hash) else {
                throw BackupSafetyError.integrity
            }
            return (file, hash)
        }
        let dto = try await api.upload(
            driveId: driveId,
            folderId: folderId,
            fileURL: resource.fileURL,
            fileName: resource.fileName,
            createdAt: date,
            mimeType: resource.mimeType,
            clientToken: MediaIntegrity
                .token("\(driveId):\(folderId):" + token + ":" + hash + ":" + resource.fileName)
        )
        guard dto.size == size, try await verify(fileId: dto.id, driveId: driveId, expectedHash: hash) else {
            throw BackupSafetyError.integrity
        }
        directoryFiles[folderId, default: []].append(dto)
        return (dto, hash)
    }

    private func verify(fileId: String, driveId: Int, expectedHash: String) async throws -> Bool {
        let url: URL
        do { url = try await api.downloadFile(driveId: driveId, fileId: fileId) } catch PhotoAPIError.notFound { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        return try MediaIntegrity.sha256(file: url) == expectedHash
    }
}

/// Shared across foreground/background engine instances; uploads and queue sweeps must not race.
actor BackupRunLock {
    static let shared = BackupRunLock()
    private var running = false
    func acquire() -> Bool {
        guard !running else { return false }
        running = true
        return true
    }

    func release() { running = false }
}
