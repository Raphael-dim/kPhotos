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

public protocol PreparedMediaIndexSyncing: AnyObject {
    func refresh(driveId: Int, rootId: String, force: Bool) async throws
}

public extension PreparedMediaIndexSyncing {
    func refresh(driveId: Int, rootId: String) async throws { try await refresh(driveId: driveId, rootId: rootId, force: false) }
}

/// Consult one prepared index, rather than inspect thousands of cloud originals on the phone.
public actor PreparedMediaIndexSync: PreparedMediaIndexSyncing {
    private let api: PhotoApiFetching
    private let writer: PhotoWriting
    private let reader: PhotoReading
    private let drives: DriveManaging
    private var lastAttempt: [String: Date] = [:]
    private var applied: [String: String] = [:]
    public init(api: PhotoApiFetching, writer: PhotoWriting, reader: PhotoReading, drives: DriveManaging) {
        self.api = api; self.writer = writer; self.reader = reader; self.drives = drives
    }

    public func refresh(driveId: Int, rootId: String, force: Bool) async throws {
        let scope = "\(driveId):\(rootId)"
        if !force, let date = lastAttempt[scope], Date().timeIntervalSince(date) < 300 { return }
        lastAttempt[scope] = Date()
        guard let (revision, index) = try await api.mediaIndex(driveId: driveId, rootId: rootId),
              force || applied[scope] != revision else { return }
        guard let selected = try drives.selectedDrive(), selected.id == driveId, selected.rootFolderId == rootId else { return }
        let hasCache = try reader.allPhotos().contains { $0.driveId == driveId && $0.libraryRootId == rootId && $0.isAvailable }
        if !hasCache, let catalogue = index.catalogue, let ids = index.availableFileIds,
           let revisions = index.availableRevisions {
            let photos = catalogue.map { file in
                var photo = PhotoSnapshot(
                    id: file.fileId,
                    driveId: driveId,
                    localIdentifier: "",
                    name: file.name,
                    takenAt: file.fallbackDate,
                    uploadedAt: file.uploadedAt,
                    mimeType: file.mimeType,
                    size: file.size,
                    isVideo: file.isVideo,
                    duration: 0,
                    albumIds: [],
                    syncStatus: .synced,
                    isFavorite: false
                )
                photo.libraryRootId = rootId; photo.remoteRevision = file.revision; photo.captureDateSource = "kdrive"
                return photo
            }
            try await writer.commitListing(photos, driveId: driveId, folderId: rootId, fileIds: Set(ids), revisions: revisions)
            if let date = index.listedAt, date.timeIntervalSince1970 > 0 {
                LibraryRefreshSchedule().markSuccess(driveId: driveId, rootId: rootId, now: date)
            } else { LibraryRefreshSchedule().invalidate(driveId: driveId, rootId: rootId) }
        }
        try await writer.applyMediaIndex(index)
        applied[scope] = revision
    }
}
