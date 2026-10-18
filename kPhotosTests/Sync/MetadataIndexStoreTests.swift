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
@testable import kPhotosCore
import RealmSwift
import XCTest

@MainActor
final class MetadataIndexStoreTests: XCTestCase {
    private func environment() throws -> (RealmAccessorImpl, Realm, PhotoManagerImpl, MetadataIndexStore) {
        let config = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString,
            objectTypes: [Photo.self, MetadataReadAttempt.self]
        )
        let realm = try Realm(configuration: config)
        let accessor = RealmAccessorImpl(configuration: config)
        return (accessor, realm, PhotoManagerImpl(realm: accessor), MetadataIndexStore(realm: accessor))
    }

    func testBackupQueuePublishesStateChangesWithoutPhotoChanges() async throws {
        let config = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString,
            objectTypes: [Photo.self, BackupItem.self]
        )
        // Keep the synchronous initializer: async overload inference would require suspension here.
        // swiftformat:disable:next redundantClosure
        let realm = try { try Realm(configuration: config) }()
        let accessor = RealmAccessorImpl(configuration: config)
        let manager = PhotoManagerImpl(realm: accessor)
        try await manager.enqueueIfAbsent(localIdentifier: "local", creationDate: Date(), isVideo: false)
        let changed = expectation(description: "Uploading state published")
        let subscription = manager.backupChangesPublisher.sink {
            if (try? manager.item(localIdentifier: "local"))?.state == .uploading { changed.fulfill() }
        }
        try await manager.markUploading(localIdentifier: "local")
        await fulfillment(of: [changed], timeout: 3)
        subscription.cancel()
        realm.refresh()
        XCTAssertEqual(realm.objects(BackupItem.self).first?.state, .uploading)
    }

    func testPausedPreparationPublishesCountsForItsOwnScope() async throws {
        let (_, realm, writer, store) = try environment()
        try await writer.upsert(photo())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "metadataPaused.7:root")
        defaults.set(true, forKey: "metadataPaused.7:other")
        let indexer = EmbeddedMetadataIndexer(
            api: IndexingAPI(),
            writer: writer,
            store: store,
            reachability: IndexingNetwork(),
            defaults: defaults
        )
        var progress = MetadataIndexProgress()
        let subscription = indexer.progressPublisher.sink { progress = $0 }
        await indexer.start(driveId: 7, rootId: "root")
        XCTAssertTrue(progress.isPaused); XCTAssertEqual(progress.libraryScope, "7:root")
        XCTAssertEqual(progress.total, 1)
        await indexer.start(driveId: 7, rootId: "other")
        XCTAssertTrue(progress.isPaused); XCTAssertEqual(progress.libraryScope, "7:other")
        XCTAssertEqual(progress.total, 0)
        subscription.cancel()
        realm.refresh()
        XCTAssertEqual(realm.objects(Photo.self).count, 1)
    }

    private func photo(
        _ id: String = "image",
        revision: String = "v1",
        root: String = "root",
        name: String = "image.jpg"
    ) -> PhotoSnapshot {
        var result = PhotoSnapshot(
            id: id,
            driveId: 7,
            localIdentifier: "",
            name: name,
            takenAt: Date(),
            uploadedAt: Date(),
            mimeType: "image/jpeg",
            size: 10,
            isVideo: false,
            duration: 0,
            albumIds: [],
            syncStatus: .synced,
            isFavorite: true
        )
        result.libraryRootId = root; result.remoteRevision = revision; return result
    }

    func testUnsupportedReadIsTerminalAndRetryPreservesTrace() async throws {
        let (_, realm, writer, store) = try environment()
        let image = photo(); try await writer.upsert(image)
        try await store.recordFailure(photo: image, error: PhotoAPIError.invalidResponse, now: Date())
        let failed = try store.batch(driveId: 7, rootId: "root", limit: 10, now: Date())
        XCTAssertEqual(failed.progress.total, 1); XCTAssertEqual(failed.progress.completed, 1)
        XCTAssertEqual(failed.progress.failed, 1); XCTAssertTrue(failed.photos.isEmpty)
        try await store.retryFailures(driveId: 7, rootId: "root")
        XCTAssertEqual(try store.batch(driveId: 7, rootId: "root", limit: 10, now: Date()).photos.count, 1)
        realm.refresh(); XCTAssertEqual(realm.objects(MetadataReadAttempt.self).first?.history.count, 2)
    }

    func testTransientFailuresHaveBoundedRetriesAndNewRevisionIsIndependent() async throws {
        let (_, realm, writer, store) = try environment()
        let image = photo(); try await writer.upsert(image)
        let now = Date(timeIntervalSince1970: 1000)
        try await store.recordFailure(photo: image, error: PhotoAPIError.network(underlying: "synthetic"), now: now)
        let delayed = try store.batch(driveId: 7, rootId: "root", limit: 10, now: now)
        XCTAssertTrue(delayed.photos.isEmpty); XCTAssertEqual(delayed.retryAt, now.addingTimeInterval(60))
        XCTAssertEqual(try store.batch(driveId: 7, rootId: "root", limit: 10, now: now.addingTimeInterval(61)).photos.count, 1)
        for _ in 0 ..< 2 {
            try await store.recordFailure(
                photo: image,
                error: PhotoAPIError.network(underlying: "synthetic"),
                now: now
            )
        }
        XCTAssertTrue(try store.batch(driveId: 7, rootId: "root", limit: 10, now: now.addingTimeInterval(10000)).photos.isEmpty)
        try await writer.upsert(photo(revision: "v2"))
        XCTAssertEqual(try store.batch(driveId: 7, rootId: "root", limit: 10, now: now).photos.first?.remoteRevision, "v2")
        realm.refresh(); XCTAssertEqual(realm.objects(MetadataReadAttempt.self).count, 1)
    }

    func testCompleteMissingGPSIsCompletedAndArchivesAreNeverQueued() async throws {
        let (_, realm, writer, store) = try environment()
        try await writer.upsert(photo()); try await writer.upsert(photo("archive", name: "image.zip"))
        try await writer.upsert(photo("other", root: "other"))
        var metadata = EmbeddedMediaMetadata(); metadata.partialRead = false; metadata.readerVersion = 2
        try await writer.updateEmbeddedMetadata(driveId: 7, fileId: "image", revision: "v1", metadata: metadata)
        let batch = try store.batch(driveId: 7, rootId: "root", limit: 10, now: Date())
        XCTAssertEqual(batch.progress.total, 1); XCTAssertEqual(batch.progress.completed, 1)
        XCTAssertEqual(batch.progress.failed, 0); XCTAssertTrue(batch.photos.isEmpty)
        realm.refresh(); XCTAssertEqual(realm.objects(Photo.self).count, 3)
    }

    func testLegacyCoverageIsUpgradedAndPartialReadPreservesConfirmedGPS() async throws {
        let (_, realm, writer, store) = try environment()
        try await writer.upsert(photo())
        var legacy = EmbeddedMediaMetadata()
        legacy.coordinate = MediaCoordinate(latitude: 48, longitude: 2)
        legacy.partialRead = false
        try await writer.updateEmbeddedMetadata(driveId: 7, fileId: "image", revision: "v1", metadata: legacy)
        XCTAssertEqual(try store.batch(driveId: 7, rootId: "root", limit: 10, now: Date()).photos.count, 1)
        var partial = EmbeddedMediaMetadata(); partial.partialRead = true; partial.readerVersion = 2
        try await writer.updateEmbeddedMetadata(driveId: 7, fileId: "image", revision: "v1", metadata: partial)
        XCTAssertEqual(try writer.photo(byFileId: "image")?.coordinate, legacy.coordinate)
        let completed = try store.batch(driveId: 7, rootId: "root", limit: 10, now: Date())
        XCTAssertEqual(completed.progress.limited, 1)
        XCTAssertEqual(completed.progress.completed, 1)
        realm.refresh(); XCTAssertEqual(realm.objects(Photo.self).count, 1)
    }

    func testNewIndexerResumesWithoutReadingCompletedOriginalAgain() async throws {
        let (_, realm, writer, store) = try environment()
        try await writer.upsert(photo("one")); try await writer.upsert(photo("two"))
        let api = IndexingAPI(); let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let first = EmbeddedMetadataIndexer(
            api: api,
            writer: writer,
            store: store,
            reachability: IndexingNetwork(),
            defaults: defaults
        )
        _ = try await first.runBatch(driveId: 7, rootId: "root", limit: 1)
        let second = EmbeddedMetadataIndexer(
            api: api,
            writer: writer,
            store: store,
            reachability: IndexingNetwork(),
            defaults: defaults
        )
        _ = try await second.runBatch(driveId: 7, rootId: "root", limit: 10)
        XCTAssertEqual(Set(api.calls), ["one", "two"]); XCTAssertEqual(api.calls.count, 2)
        XCTAssertEqual(try store.batch(driveId: 7, rootId: "root", limit: 10, now: Date()).progress.completed, 2)
        realm.refresh(); XCTAssertEqual(realm.objects(Photo.self).count, 2)
        XCTAssertTrue(try XCTUnwrap(writer.photo(byFileId: "one")).isFavorite)
    }

    func testCanceledOriginalDoesNotBecomeFailureOrCompletion() async throws {
        let (_, realm, writer, store) = try environment(); try await writer.upsert(photo())
        let api = IndexingAPI(); api.delayed = true
        let indexer = EmbeddedMetadataIndexer(api: api, writer: writer, store: store, reachability: IndexingNetwork())
        let task = Task { try await indexer.runBatch(driveId: 7, rootId: "root", limit: 1) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let batch = try store.batch(driveId: 7, rootId: "root", limit: 10, now: Date())
        XCTAssertEqual(batch.progress.completed, 0); XCTAssertEqual(batch.progress.failed, 0)
        realm.refresh(); XCTAssertTrue(realm.objects(MetadataReadAttempt.self).isEmpty)
    }
}

private final class IndexingAPI: LibraryTestAPI {
    var calls: [String] = []
    var delayed = false
    override func originalMetadata(driveId: Int, fileId: String, isVideo: Bool) async throws -> EmbeddedMediaMetadata {
        calls.append(fileId)
        if delayed { try await Task.sleep(nanoseconds: 5_000_000_000) }
        var metadata = EmbeddedMediaMetadata(); metadata.partialRead = false; metadata.readerVersion = 2
        metadata.coordinate = MediaCoordinate(latitude: 48, longitude: 2)
        return metadata
    }
}

private final class IndexingNetwork: NetworkReachable {
    func currentKind() -> NetworkKind { .wifi }
    func allowsSync(under policy: SyncNetworkPolicy) -> Bool { true }
}
