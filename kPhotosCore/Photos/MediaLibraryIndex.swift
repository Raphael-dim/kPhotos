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

/// kPhotos' own cache, built from original media. It is unrelated to Google archives and sidecars.
public struct MediaLibraryIndex: Codable, Sendable {
    public static let folderName = ".kphotos-index"
    public static let producerName = "kphotos-original-media-v1"
    public var schemaVersion = 1
    public var producer = producerName
    public let driveId: Int
    public let rootId: String
    public var generatedAt: Date
    public var totalMedia: Int
    public var pending: Int
    public var failed: Int
    public var records: [MediaIndexRecord]
    public var catalogue: [MediaFileDescriptor]?
    public var availableFileIds: [String]?
    public var availableRevisions: [String: String]?
    public var listedAt: Date?
    public var cacheFolderId: String?

    public init(driveId: Int, rootId: String, totalMedia: Int, pending: Int, failed: Int, records: [MediaIndexRecord]) {
        self.driveId = driveId
        self.rootId = rootId
        self.generatedAt = Date()
        self.totalMedia = totalMedia
        self.pending = pending
        self.failed = failed
        self.records = records
    }

    public func validate(driveId: Int, rootId: String) throws {
        guard schemaVersion == 1, producer == Self.producerName,
              self.driveId == driveId, self.rootId == rootId,
              totalMedia >= 0, totalMedia <= 100_000, pending >= 0, failed >= 0,
              pending <= totalMedia, failed <= totalMedia,
              records.count <= totalMedia, records.count + pending + failed == totalMedia,
              Set(records.map(\.fileId)).count == records.count else { throw PhotoAPIError.invalidResponse }
        if let catalogue {
            guard catalogue.count == totalMedia, Set(catalogue.map(\.fileId)).count == totalMedia,
                  let availableFileIds, let availableRevisions, let listedAt,
                  availableFileIds.count <= 200_000, availableRevisions.count <= 200_000,
                  listedAt.timeIntervalSince1970.isFinite else { throw PhotoAPIError.invalidResponse }
            let available = Set(availableFileIds)
            for file in catalogue {
                guard !file.fileId.isEmpty, file.fileId.count <= 128, file.size >= 0,
                      available.contains(file.fileId), availableRevisions[file.fileId] == file.revision,
                      RemoteFileDTO.isSupportedMedia(name: file.name, mimeType: file.mimeType),
                      file.uploadedAt.timeIntervalSince1970.isFinite, file.fallbackDate.timeIntervalSince1970.isFinite else {
                    throw PhotoAPIError.invalidResponse
                }
            }
        }
        let catalogueRevisions = catalogue.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.fileId, $0.revision) }) }
        for record in records {
            if let catalogueRevisions, catalogueRevisions[record.fileId] != record.revision {
                throw PhotoAPIError.invalidResponse
            }
            guard !record.fileId.isEmpty, record.fileId.count <= 128,
                  !record.revision.isEmpty, record.revision.count <= 512 else { throw PhotoAPIError.invalidResponse }
            if let pack = record.thumbnailPack {
                guard pack.folderId == cacheFolderId, !pack.fileId.isEmpty, pack.fileId.count <= 128,
                      pack.sha256.count == 64, pack.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw PhotoAPIError.invalidResponse
                }
            }
            if let coordinate = record.metadata.coordinate,
               MediaCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) == nil {
                throw PhotoAPIError.invalidResponse
            }
            if let date = record.metadata.captureDate, !date.timeIntervalSince1970.isFinite {
                throw PhotoAPIError.invalidResponse
            }
        }
    }

    public static func decode(_ data: Data, driveId: Int, rootId: String) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw PhotoAPIError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(Self.self, from: data)
        try index.validate(driveId: driveId, rootId: rootId)
        return index
    }

    public func encode() throws -> Data {
        try validate(driveId: driveId, rootId: rootId)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 32 * 1024 * 1024 else { throw PhotoAPIError.invalidResponse }
        return data
    }
}

public struct MediaIndexRecord: Codable, Sendable {
    public let fileId: String
    public let revision: String
    public let metadata: EmbeddedMediaMetadata
    public var thumbnailPack: ThumbnailPackReference?
    public init(fileId: String, revision: String, metadata: EmbeddedMediaMetadata) {
        self.fileId = fileId
        self.revision = revision
        self.metadata = metadata
    }
}

/// Complete primary-media listing, enabling a new phone to bootstrap without crawling every dated folder.
public struct MediaFileDescriptor: Codable, Sendable {
    public let fileId: String
    public let revision: String
    public let name: String
    public let mimeType: String
    public let size: Int64
    public let isVideo: Bool
    public let uploadedAt: Date
    public let fallbackDate: Date
    public init(photo: PhotoSnapshot) {
        self.fileId = photo.fileId; self.revision = photo.remoteRevision; self.name = photo.name
        self.mimeType = photo.mimeType; self.size = photo.size; self.isVideo = photo.isVideo
        self.uploadedAt = photo.uploadedAt; self.fallbackDate = photo.takenAt
    }

    public init(file: RemoteFileDTO) {
        self.fileId = file.id; self.revision = file.revision; self.name = file.name; self.mimeType = file.mimeType; self
            .size = file.size
        self.isVideo = file.isVideoMedia
        self.uploadedAt = Date(timeIntervalSince1970: TimeInterval(file.addedAt > 0 ? file.addedAt : file.lastModifiedAt))
        self.fallbackDate = Date(timeIntervalSince1970: TimeInterval(file.bestTakenAt))
    }
}
