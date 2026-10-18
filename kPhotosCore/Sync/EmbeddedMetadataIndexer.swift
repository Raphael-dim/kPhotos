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

public struct MetadataIndexProgress: Equatable, Sendable {
    public var libraryScope: String?
    public var isPaused = false
    public var isRunning = false
    public var completed = 0
    public var total = 0
    public var failed = 0
    public var limited = 0
    public init(isRunning: Bool = false, completed: Int = 0, total: Int = 0, failed: Int = 0, limited: Int = 0) {
        self.isRunning = isRunning; self.completed = completed; self.total = total; self.failed = failed; self.limited = limited
    }
}

public protocol EmbeddedMetadataIndexing: AnyObject {
    var progressPublisher: AnyPublisher<MetadataIndexProgress, Never> { get }
    func start(driveId: Int, rootId: String) async
    func stop() async
    func suspend() async
    func retry(driveId: Int, rootId: String) async
    func runBatch(driveId: Int, rootId: String, limit: Int) async throws -> Bool
}

/// One worker shared by foreground and OS background tasks. Checkpoints are persisted per original revision.
public actor EmbeddedMetadataIndexer: EmbeddedMetadataIndexing {
    private let api: PhotoApiFetching
    private let writer: PhotoWriting
    private let store: MetadataIndexStoring
    private let reachability: NetworkReachable
    private let publisher: MediaIndexPublishing?
    private let defaults: UserDefaults
    private let subject = CurrentValueSubject<MetadataIndexProgress, Never>(.init())
    private var worker: Task<Void, Never>?
    private var scope: String?
    private var busy = false
    private var generation = UUID()
    public nonisolated var progressPublisher: AnyPublisher<MetadataIndexProgress, Never> { subject.eraseToAnyPublisher() }

    public init(
        api: PhotoApiFetching,
        writer: PhotoWriting,
        store: MetadataIndexStoring,
        reachability: NetworkReachable,
        defaults: UserDefaults = .standard,
        publisher: MediaIndexPublishing? = nil
    ) {
        self.api = api; self.writer = writer; self.store = store; self.reachability = reachability; self.defaults = defaults; self
            .publisher = publisher
    }

    private func pauseKey(_ scope: String) -> String { "metadataPaused." + scope }

    public func start(driveId: Int, rootId: String) async {
        let requested = "\(driveId):\(rootId)"
        if scope == requested, worker != nil { return }
        let request = UUID(); generation = request
        let previous = worker; previous?.cancel()
        if let previous { await previous.value }
        guard generation == request else { return }
        scope = requested
        worker = nil
        if subject.value.libraryScope != requested {
            var progress = MetadataIndexProgress(); progress.libraryScope = requested; subject.send(progress)
        }
        if defaults.bool(forKey: pauseKey(requested)) {
            do {
                var progress = try store.batch(driveId: driveId, rootId: rootId, limit: 0, now: Date()).progress
                progress.libraryScope = requested; progress.isPaused = true; subject.send(progress)
            } catch {
                // Keep an unknown status rather than reuse another library's completion claim.
                var progress = MetadataIndexProgress(); progress.libraryScope = requested
                progress.isPaused = true; subject.send(progress)
            }
            return
        }
        worker = Task {
            defer { if self.generation == request { self.worker = nil } }
            do {
                while !Task.isCancelled {
                    let more = try await self.runBatch(driveId: driveId, rootId: rootId, limit: 64)
                    if !more { break }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                // Cancellation/offline/auth errors stop this session; durable attempts survive the next activation.
                var progress = self.subject.value; progress.isRunning = false; self.subject.send(progress)
            }
        }
    }

    static func isMedia(_ photo: PhotoSnapshot) -> Bool {
        RemoteFileDTO.isSupportedMedia(name: photo.name, mimeType: photo.mimeType)
    }

    public func stop() async {
        if let scope { defaults.set(true, forKey: pauseKey(scope)) }
        await suspend()
        var progress = subject.value; progress.isPaused = true; subject.send(progress)
    }

    public func suspend() async {
        let request = UUID(); generation = request
        let previous = worker; previous?.cancel()
        if let previous { await previous.value }
        guard generation == request else { return }
        worker = nil
        var progress = subject.value; progress.isRunning = false; subject.send(progress)
    }

    public func retry(driveId: Int, rootId: String) async {
        await suspend()
        do {
            try await store.retryFailures(driveId: driveId, rootId: rootId)
            defaults.set(false, forKey: pauseKey("\(driveId):\(rootId)"))
            await start(driveId: driveId, rootId: rootId)
        } catch { /* A database error leaves existing metadata intact; the next explicit retry may recover. */ }
    }

    public func runBatch(driveId: Int, rootId: String, limit: Int) async throws -> Bool {
        guard !busy, !defaults.bool(forKey: pauseKey("\(driveId):\(rootId)")) else { return false }
        busy = true; defer { busy = false }
        let decoderKey = "metadataDecoderVersion.\(driveId):\(rootId)"
        if defaults.integer(forKey: decoderKey) < 3 {
            try await store.retryFailures(driveId: driveId, rootId: rootId)
            defaults.set(3, forKey: decoderKey)
        }
        let batch = try store.batch(driveId: driveId, rootId: rootId, limit: limit, now: Date())
        defaults.set(
            [
                "completed": batch.progress.completed,
                "total": batch.progress.total,
                "errors": batch.failureCodes,
                "updatedAt": Date().timeIntervalSince1970
            ],
            forKey: "metadataDiagnosticSummary"
        )
        var progress = batch.progress; progress.libraryScope = "\(driveId):\(rootId)"
        progress.isRunning = !batch.photos.isEmpty
        subject.send(progress)
        guard reachability.currentKind() == .wifi || reachability.currentKind() == .other else {
            progress.isRunning = false; subject.send(progress); return false
        }
        for photo in batch.photos {
            try Task.checkCancellation()
            guard reachability.currentKind() == .wifi || reachability.currentKind() == .other else {
                progress.isRunning = false; subject.send(progress); return false
            }
            do {
                let metadata = try await api.originalMetadata(driveId: driveId, fileId: photo.fileId, isVideo: photo.isVideo)
                try Task.checkCancellation()
                try await writer.updateEmbeddedMetadata(
                    driveId: driveId,
                    fileId: photo.fileId,
                    revision: photo.remoteRevision,
                    metadata: metadata
                )
                progress.completed += 1
                if batch.failedFileIds.contains(photo.fileId) { progress.failed -= 1 }
            } catch {
                try Task.checkCancellation()
                recordDiagnostic(error: error, photo: photo)
                let terminal = try await store.recordFailure(photo: photo, error: error, now: Date())
                if terminal { progress.completed += 1 }
                if !batch.failedFileIds.contains(photo.fileId) { progress.failed += 1 }
                if case PhotoAPIError.unauthorized = error { throw error }
            }
            subject.send(progress)
        }
        return try await finishBatch(driveId: driveId, rootId: rootId)
    }

    private func finishBatch(driveId: Int, rootId: String) async throws -> Bool {
        let next = try store.batch(driveId: driveId, rootId: rootId, limit: 1, now: Date())
        var final = next.progress; final.libraryScope = "\(driveId):\(rootId)"
        final.isRunning = !next.photos.isEmpty; subject.send(final)
        if next.photos.isEmpty, let retry = next.retryAt {
            try await Task.sleep(nanoseconds: UInt64(max(1, min(60, retry.timeIntervalSinceNow))) * 1_000_000_000)
            return true
        }
        if next.photos.isEmpty, next.progress.completed == next.progress.total, !Task.isCancelled {
            do {
                try await publisher?.publishIfNeeded(driveId: driveId, rootId: rootId)
            } catch {
                // The publisher retains sanitized failure diagnostics. Local preparation remains usable.
            }
        }
        return !next.photos.isEmpty
    }

    private func recordDiagnostic(error: Error, photo: PhotoSnapshot) {
        let failure = error as NSError
        let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        let timeout: Bool
        if case PhotoAPIError.network(let reason) = error {
            timeout = reason == "metadata-read-timeout"
        } else { timeout = false }
        let knownDomains = ["NSURLErrorDomain", "AVFoundationErrorDomain", "NSCocoaErrorDomain"]
        defaults.set([
            "domain": knownDomains.contains(failure.domain) ? failure.domain : "other",
            "code": failure.code, "isVideo": photo.isVideo, "size": photo.size, "timeout": timeout,
            "underlyingDomain": knownDomains.contains(underlying?.domain ?? "") ? underlying?.domain ?? "" : "other",
            "underlyingCode": underlying?.code ?? 0,
            "updatedAt": Date().timeIntervalSince1970
        ], forKey: "metadataLastFailure")
    }
}
