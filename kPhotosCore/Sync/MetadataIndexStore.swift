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

public struct MetadataIndexBatch: Sendable {
    public var progress: MetadataIndexProgress
    public let photos: [PhotoSnapshot]
    public let retryAt: Date?
    public var failedFileIds: Set<String> = []
    public var failureCodes: [String: Int] = [:]
}

public protocol MetadataIndexStoring: AnyObject {
    func batch(driveId: Int, rootId: String, limit: Int, now: Date) throws -> MetadataIndexBatch
    @discardableResult
    func recordFailure(photo: PhotoSnapshot, error: Error, now: Date) async throws -> Bool
    func retryFailures(driveId: Int, rootId: String) async throws
}

/// Queue policy and durable diagnostics belong here, independently of networking and UI lifecycle.
public final class MetadataIndexStore: MetadataIndexStoring {
    private let realm: RealmAccessor
    public init(realm: RealmAccessor) { self.realm = realm }
    private static func scope(_ drive: Int, _ root: String) -> String { "\(drive):\(root)" }
    private static func key(_ photo: PhotoSnapshot) -> String {
        "\(scope(photo.driveId, photo.libraryRootId)):\(photo.fileId):\(photo.remoteRevision)"
    }

    public func batch(driveId: Int, rootId: String, limit: Int, now: Date) throws -> MetadataIndexBatch {
        try realm.read { realm in
            let photos = realm.objects(Photo.self)
                .filter(
                    "driveId == %@ AND libraryRootId == %@ AND isAvailable == true",
                    driveId,
                    rootId
                )
                .map(PhotoSnapshot.init)
                .filter(EmbeddedMetadataIndexer.isMedia)
                .sorted { $0.takenAt > $1.takenAt }
            let attempts = Dictionary(
                uniqueKeysWithValues: realm.objects(MetadataReadAttempt.self)
                    .filter("scope == %@", Self.scope(driveId, rootId))
                    .map { ($0.id, $0) }
            )
            var progress = MetadataIndexProgress(total: photos.count)
            var pending: [PhotoSnapshot] = []; var nextRetry: Date?; var failedIds = Set<String>()
            var failureCodes: [String: Int] = [:]
            for photo in photos {
                if let metadata = photo.embeddedMetadata, metadata.partialRead != nil,
                   metadata.readerVersion == 2,
                   photo.embeddedMetadataRevision == photo.remoteRevision {
                    progress.completed += 1
                    if photo.embeddedMetadata?.isPartial == true { progress.limited += 1 }
                    continue
                }
                if let attempt = attempts[Self.key(photo)] {
                    progress.failed += 1; failedIds.insert(photo.fileId)
                    failureCodes[attempt.errorCode, default: 0] += 1
                    if attempt.terminal { progress.completed += 1; continue }
                    if let retry = attempt.nextRetryAt, retry > now {
                        nextRetry = min(nextRetry ?? retry, retry); continue
                    }
                }
                if pending.count < limit { pending.append(photo) }
            }
            return MetadataIndexBatch(
                progress: progress,
                photos: pending,
                retryAt: nextRetry,
                failedFileIds: failedIds,
                failureCodes: failureCodes
            )
        }
    }

    @discardableResult
    public func recordFailure(photo: PhotoSnapshot, error: Error, now: Date) async throws -> Bool {
        let code: String
        let permanent: Bool
        switch error {
        case PhotoAPIError.unauthorized: code = "authorization"; permanent = false
        case PhotoAPIError.notFound: code = "not-found"; permanent = true
        case PhotoAPIError.invalidResponse: code = "unreadable"; permanent = true
        case PhotoAPIError.decoding: code = "unsupported"; permanent = true
        case PhotoAPIError.rateLimited: code = "rate-limit"; permanent = false
        case PhotoAPIError.server(let status, _): code = "http-\(status)"; permanent = (400 ..< 500)
            .contains(status) && status != 429
        case PhotoAPIError.network(let reason):
            code = reason == "metadata-read-timeout" ? "metadata-timeout" : "network"
            permanent = false
        default:
            let failure = error as NSError
            let category = [
                "NSURLErrorDomain": "network",
                "AVFoundationErrorDomain": "media",
                "NSCocoaErrorDomain": "encoding"
            ][failure.domain] ?? "reader"
            code = category + "-" + String(failure.code)
            permanent = false
        }
        return try await realm.writeReturning { realm in
            let key = Self.key(photo)
            let attempt = realm.object(ofType: MetadataReadAttempt.self, forPrimaryKey: key) ?? MetadataReadAttempt()
            if attempt.realm == nil { attempt.id = key }
            attempt.scope = Self.scope(photo.driveId, photo.libraryRootId)
            attempt.fileId = photo.fileId; attempt.revision = photo.remoteRevision
            attempt.failures += 1; attempt.errorCode = code
            attempt.terminal = permanent || attempt.failures >= 3
            attempt.nextRetryAt = attempt.terminal ? nil : now.addingTimeInterval(attempt.failures == 1 ? 60 : 300)
            attempt.history.append("\(Int(now.timeIntervalSince1970)):\(code)")
            realm.add(attempt, update: .modified)
            return attempt.terminal
        }
    }

    public func retryFailures(driveId: Int, rootId: String) async throws {
        try await realm.write { realm in
            for attempt in realm.objects(MetadataReadAttempt.self).filter("scope == %@", Self.scope(driveId, rootId)) {
                attempt.failures = 0; attempt.terminal = false; attempt.nextRetryAt = nil
                attempt.history.append("\(Int(Date().timeIntervalSince1970)):user-retry")
            }
        }
    }
}
