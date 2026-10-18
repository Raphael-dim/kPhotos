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

import CryptoKit
import Foundation

public protocol MediaIndexPublishing: AnyObject {
    func publishIfNeeded(driveId: Int, rootId: String) async throws
}

/// A complete preparation is reusable after reinstall; only a single app-owned cache file per installation is updated.
public actor MediaIndexPublisher: MediaIndexPublishing {
    private struct PendingUpload: Codable { let fingerprint: String; let date: Date; let clientToken: String }
    private let api: PhotoApiFetching
    private let reader: PhotoReading
    private let defaults: UserDefaults
    public init(api: PhotoApiFetching, reader: PhotoReading, defaults: UserDefaults = .standard) {
        self.api = api; self.reader = reader; self.defaults = defaults
    }

    private static func makeIndex(photos: [PhotoSnapshot], driveId: Int, rootId: String) -> MediaLibraryIndex {
        let records = photos.compactMap { photo -> MediaIndexRecord? in
            guard photo.embeddedMetadataRevision == photo.remoteRevision,
                  let metadata = photo.embeddedMetadata else { return nil }
            return MediaIndexRecord(fileId: photo.fileId, revision: photo.remoteRevision, metadata: metadata)
        }
        var index = MediaLibraryIndex(
            driveId: driveId,
            rootId: rootId,
            totalMedia: photos.count,
            pending: 0,
            failed: photos.count - records.count,
            records: records
        )
        index.catalogue = photos.map(MediaFileDescriptor.init)
        index.availableFileIds = Array(Set(photos.flatMap { [$0.fileId] + $0.resourceFileIds })).sorted()
        var revisions: [String: String] = [:]
        for photo in photos {
            revisions.merge(photo.resourceRevisions) { _, new in
                new
            }; revisions[photo.fileId] = photo.remoteRevision
        }
        index.availableRevisions = revisions
        index.listedAt = Date(timeIntervalSince1970: 0); index.generatedAt = Date(timeIntervalSince1970: 0)
        return index
    }

    public func publishIfNeeded(driveId: Int, rootId: String) async throws {
        let photos = try reader.allPhotos()
            .filter { $0.driveId == driveId && $0.libraryRootId == rootId && $0.isAvailable
                && EmbeddedMetadataIndexer.isMedia($0)
            }
            .sorted { $0.fileId < $1.fileId }
        guard !photos.isEmpty else { return }
        var index = Self.makeIndex(photos: photos, driveId: driveId, rootId: rootId)
        let fingerprint = try SHA256.hash(data: index.encode()).map { String(format: "%02x", $0) }.joined()
        let key = "mediaIndexUpload.\(driveId).\(rootId)"
        let previous = try defaults.data(forKey: key).map { try JSONDecoder().decode(MediaIndexUploadState.self, from: $0) }
        if previous?.fingerprint == fingerprint { return }
        let installationKey = "mediaIndexInstallation"
        let installation = defaults.string(forKey: installationKey) ?? UUID().uuidString
        defaults.set(installation, forKey: installationKey)
        let pendingKey = key + ".pending"
        let existingPending = try defaults.data(forKey: pendingKey).map { try JSONDecoder().decode(PendingUpload.self, from: $0) }
        let pending: PendingUpload
        if let existingPending, existingPending.fingerprint == fingerprint {
            pending = existingPending
        } else {
            pending = PendingUpload(fingerprint: fingerprint, date: Date(), clientToken: UUID().uuidString)
        }
        try defaults.set(JSONEncoder().encode(pending), forKey: pendingKey)
        index.generatedAt = pending.date
        // A fresh listing is still required to establish availability; restored snapshots are not claimed current.
        index.listedAt = Date(timeIntervalSince1970: 0)
        let state: MediaIndexUploadState
        do {
            state = try await api.saveMediaIndex(
                index,
                name: "index-ios-" + installation + ".json",
                previous: previous,
                clientToken: pending.clientToken
            )
        } catch {
            let event = "\(Int(Date().timeIntervalSince1970)):export-error-\((error as NSError).code)"
            defaults.set(event, forKey: key + ".lastError")
            defaults.set((defaults.stringArray(forKey: key + ".history") ?? []) + [event], forKey: key + ".history")
            throw error
        }
        var saved = state; saved.fingerprint = fingerprint
        try defaults.set(JSONEncoder().encode(saved), forKey: key)
        defaults.removeObject(forKey: key + ".lastError")
        defaults.removeObject(forKey: pendingKey)
    }
}
