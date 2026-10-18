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

/// Builds a complete snapshot before committing anything. A failed page leaves the old index intact.
struct LibraryScanner {
    let api: PhotoApiFetching

    static func shouldVisit(_ name: String) -> Bool {
        !name.hasPrefix(".") && ![
            "Google Takout",
            "Google Takeout",
            "04_Journaux",
            "05_Paquet_kDrive_compact",
            "Archives_documents_et_rapports",
            "03_A_examiner",
            "Corbeille_Google"
        ].contains(name)
    }

    func scan(
        driveId: Int,
        rootId: String
    ) async throws -> (photos: [PhotoSnapshot], fileIds: Set<String>, revisions: [String: String]) {
        var folders = [rootId]
        var visited = Set<String>()
        var media: [RemoteFileDTO] = []
        var fileIds = Set<String>()
        var revisions: [String: String] = [:]
        while let folderId = folders.popLast() {
            try Task.checkCancellation()
            guard visited.insert(folderId).inserted else { continue }
            var cursor: String?
            var cursors = Set<String>()
            repeat {
                let page = try await api.listFolder(driveId: driveId, folderId: folderId, cursor: cursor, limit: 100)
                for file in page.items {
                    revisions[file.id] = file.revision
                    if !file.isDirectory,
                       !["uploading", "trashed", "trash_inherited"].contains(file.status) { fileIds.insert(file.id) }
                    if file.isDirectory {
                        if Self.shouldVisit(file.name) { folders.append(file.id) }
                    } else if file.isMedia, !file.name.contains("__kphotos_resource_") {
                        media.append(file)
                    }
                    // Archives, catalogues and sidecars are never opened by the gallery.
                }
                cursor = page.nextCursor
                if let cursor, !cursors.insert(cursor).inserted { throw PhotoAPIError.invalidResponse }
            } while cursor != nil
        }
        let photos = media.map { file in
            var snapshot = PhotoSyncEngine.makeSnapshot(from: file, driveId: driveId)
            snapshot.libraryRootId = rootId
            return snapshot
        }
        return (photos, fileIds, revisions)
    }
}

/// Cache-first opening; only a completed scan advances freshness. Pull-to-refresh is always explicit.
public struct LibraryRefreshSchedule {
    private let defaults: UserDefaults
    private let interval: TimeInterval
    public init(defaults: UserDefaults = .standard, interval: TimeInterval = 900) {
        self.defaults = defaults
        self.interval = interval
    }

    private func key(driveId: Int, rootId: String) -> String { "libraryRefresh.\(driveId).\(rootId)" }
    public func invalidate(driveId: Int, rootId: String) { defaults.set(-1, forKey: key(driveId: driveId, rootId: rootId)) }
    public func markSuccess(driveId: Int, rootId: String, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: key(driveId: driveId, rootId: rootId))
    }

    public func shouldRefresh(driveId: Int, rootId: String, hasCache: Bool, now: Date = Date()) -> Bool {
        guard hasCache else { return true }
        let stamp = defaults.double(forKey: key(driveId: driveId, rootId: rootId))
        if stamp == 0 {
            // Upgrade with an existing index: use it immediately, schedule a later check.
            markSuccess(driveId: driveId, rootId: rootId, now: now)
            return false
        }
        return now.timeIntervalSince1970 - stamp >= interval
    }
}
