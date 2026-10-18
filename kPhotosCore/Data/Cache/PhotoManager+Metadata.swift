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
import RealmSwift

public extension PhotoManagerImpl {
    func updateEmbeddedMetadata(
        driveId: Int,
        fileId: String,
        revision: String,
        metadata: EmbeddedMediaMetadata
    ) async throws {
        let json = try Self.encodeJSON(metadata)
        try await realm.write { realm in
            guard let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId),
                  photo.driveId == driveId, photo.isAvailable, photo.remoteRevision == revision else { return }
            photo.embeddedMetadataJSON = json
            photo.embeddedMetadataRevision = revision
            if let coordinate = metadata.coordinate {
                photo.latitude = coordinate.latitude; photo.longitude = coordinate.longitude; photo.locationSource = "embedded"
            } else if photo.locationSource != "photokit", !metadata.isPartial {
                photo.latitude = nil; photo.longitude = nil; photo.locationSource = ""
            }
            if let duration = metadata.duration { photo.duration = duration }
            if let date = metadata.captureDate, photo.localIdentifier.isEmpty {
                photo.takenAt = date
                photo.captureDateSource = metadata.hasExplicitTimezone ? "embedded_offset" : "embedded_local"
            }
        }
    }

    /// A prepared index applies in one transaction, preserving all unrelated client state.
    func applyMediaIndex(_ index: MediaLibraryIndex) async throws {
        try index.validate(driveId: index.driveId, rootId: index.rootId)
        let records = try index.records.map { record in
            try (
                record,
                Self.encodeJSON(record.metadata),
                record.thumbnailPack.map { try Self.encodeJSON($0) }
            )
        }
        try await realm.write { realm in
            for (record, json, pack) in records {
                guard let photo = realm.object(ofType: Photo.self, forPrimaryKey: record.fileId),
                      photo.driveId == index.driveId, photo.libraryRootId == index.rootId, photo.isAvailable,
                      photo.remoteRevision == record.revision else { continue }
                if let pack { photo.thumbnailPackJSON = pack }
                photo.embeddedMetadataJSON = json
                photo.embeddedMetadataRevision = record.revision
                if let coordinate = record.metadata.coordinate {
                    photo.latitude = coordinate.latitude; photo.longitude = coordinate.longitude; photo
                        .locationSource = "embedded"
                } else if photo.locationSource != "photokit", !record.metadata.isPartial {
                    photo.latitude = nil; photo.longitude = nil; photo.locationSource = ""
                }
                if let date = record.metadata.captureDate, photo.localIdentifier.isEmpty {
                    photo.takenAt = date
                    photo.captureDateSource = record.metadata.hasExplicitTimezone ? "embedded_offset" : "embedded_local"
                }
            }
        }
    }

    internal static func encodeJSON(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "JSON must be UTF-8"))
        }
        return text
    }
}
