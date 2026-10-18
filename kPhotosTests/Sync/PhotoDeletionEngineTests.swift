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

@testable import kPhotosCore
import XCTest

/// Classifier de retry côté suppression — pendant de `BackupRetryClassifier`.
/// Backoff plus court (base 15s) car un DELETE est léger côté serveur.
final class DeletionRetryClassifierTests: XCTestCase {
    func testNetwork_isTransient_withBase15s() {
        let decision = DeletionRetryClassifier.classify(
            error: PhotoAPIError.network(underlying: "down"), attemptCount: 1
        )
        guard case .transient(let retryAfter) = decision else {
            XCTFail("Attendu .transient, obtenu \(decision)")
            return
        }
        XCTAssertEqual(retryAfter, 15, accuracy: 0.01)
    }

    func testRateLimitedAndServer5xx_areTransient() {
        guard case .transient = DeletionRetryClassifier.classify(
            error: PhotoAPIError.rateLimited(retryAfter: nil), attemptCount: 1
        ) else {
            XCTFail("rateLimited doit être transient")
            return
        }
        guard case .transient = DeletionRetryClassifier.classify(
            error: PhotoAPIError.server(statusCode: 503, message: nil), attemptCount: 1
        ) else {
            XCTFail("5xx doit être transient")
            return
        }
    }

    func testNotFound_isPermanent() {
        // 404 sur DELETE = la photo a déjà disparu côté serveur — rien à rejouer.
        XCTAssertEqual(
            DeletionRetryClassifier.classify(error: PhotoAPIError.notFound, attemptCount: 1),
            .permanent
        )
    }

    func testUnauthorizedAndServer4xx_arePermanent() {
        XCTAssertEqual(
            DeletionRetryClassifier.classify(error: PhotoAPIError.unauthorized, attemptCount: 1),
            .permanent
        )
        XCTAssertEqual(
            DeletionRetryClassifier.classify(
                error: PhotoAPIError.server(statusCode: 403, message: nil), attemptCount: 1
            ),
            .permanent
        )
    }

    func testDecodingError_isPermanent() {
        XCTAssertEqual(
            DeletionRetryClassifier.classify(
                error: PhotoAPIError.decoding(underlying: "x"), attemptCount: 1
            ),
            .permanent
        )
    }

    func testNonApiError_isTransient() {
        guard case .transient = DeletionRetryClassifier.classify(
            error: CocoaError(.fileNoSuchFile), attemptCount: 1
        ) else {
            XCTFail("Une erreur inconnue doit être retentée au moins une fois")
            return
        }
    }

    func testEscalatesToPermanent_pastMaxTransientAttempts() {
        let decision = DeletionRetryClassifier.classify(
            error: PhotoAPIError.network(underlying: "still down"),
            attemptCount: DeletionRetryClassifier.maxTransientAttempts + 1
        )
        XCTAssertEqual(decision, .permanent)
    }

    func testBackoff_isExponential_andCappedAt1h() {
        XCTAssertEqual(DeletionRetryClassifier.backoff(forAttempt: 1, base: 15), 15, accuracy: 0.1)
        XCTAssertEqual(DeletionRetryClassifier.backoff(forAttempt: 2, base: 15), 30, accuracy: 0.1)
        XCTAssertEqual(DeletionRetryClassifier.backoff(forAttempt: 3, base: 15), 60, accuracy: 0.1)
        XCTAssertEqual(DeletionRetryClassifier.backoff(forAttempt: 100, base: 15), 3600, accuracy: 0.1)
    }
}

/// Drain de la file de suppression — orchestration séquentielle DELETE + transitions.
final class PhotoDeletionEngineTests: XCTestCase {
    func testDrain_emptyQueue_returnsZeroResult() async {
        let engine = makeEngine(
            reader: FakeDeletionQueueReader(),
            writer: FakeDeletionQueueWriter(),
            api: FakeDeletionApi()
        )
        let result = await engine.drain { _ in }
        XCTAssertEqual(result, DeletionSessionResult(completed: 0, failedPermanently: 0, failedTransiently: 0))
    }

    func testDrain_successfulDelete_marksDeletingThenCompleted() async {
        let reader = FakeDeletionQueueReader()
        reader.items = [item(fileId: "F1")]
        let writer = FakeDeletionQueueWriter()
        let api = FakeDeletionApi()

        let result = await makeEngine(reader: reader, writer: writer, api: api).drain { _ in }

        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(api.deletedFileIds, ["F1"])
        XCTAssertEqual(writer.markedDeleting, ["F1"])
        XCTAssertEqual(writer.markedCompleted, ["F1"])
    }

    func testDrain_transientError_marksFailedTransient() async {
        let reader = FakeDeletionQueueReader()
        reader.items = [item(fileId: "F1")]
        let writer = FakeDeletionQueueWriter()
        let api = FakeDeletionApi()
        api.deleteFileError = PhotoAPIError.network(underlying: "offline")

        let result = await makeEngine(reader: reader, writer: writer, api: api).drain { _ in }

        XCTAssertEqual(result.failedTransiently, 1)
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(writer.markedFailedTransient, ["F1"])
        XCTAssertTrue(writer.markedCompleted.isEmpty)
    }

    func testDrain_permanentError_marksFailedPermanent() async {
        let reader = FakeDeletionQueueReader()
        reader.items = [item(fileId: "F1")]
        let writer = FakeDeletionQueueWriter()
        let api = FakeDeletionApi()
        api.deleteFileError = PhotoAPIError.unauthorized

        let result = await makeEngine(reader: reader, writer: writer, api: api).drain { _ in }

        XCTAssertEqual(result.failedPermanently, 1)
        XCTAssertEqual(writer.markedFailedPermanent, ["F1"])
    }

    func testDrain_sweepsOrphanedDeletionsBeforeProcessing() async {
        let writer = FakeDeletionQueueWriter()
        _ = await makeEngine(reader: FakeDeletionQueueReader(), writer: writer, api: FakeDeletionApi())
            .drain { _ in }
        XCTAssertEqual(
            writer.resetOrphanedCallCount,
            1,
            "Le drain doit balayer les items bloqués en .deleting avant de traiter"
        )
    }

    func testDrain_reportsProgressFromZeroToTotal() async {
        let reader = FakeDeletionQueueReader()
        reader.items = [item(fileId: "F1"), item(fileId: "F2")]
        let collector = ProgressCollector()

        _ = await makeEngine(reader: reader, writer: FakeDeletionQueueWriter(), api: FakeDeletionApi())
            .drain { progress in await collector.record(progress) }

        let updates = await collector.updates
        XCTAssertEqual(updates.first?.total, 2)
        XCTAssertEqual(updates.first?.completed, 0)
        XCTAssertEqual(updates.last?.completed, 2)
        XCTAssertEqual(updates.last?.total, 2)
    }

    func testUserFacingReason_forApiError_usesLocalizedDescription() {
        XCTAssertEqual(
            PhotoDeletionEngine.userFacingReason(from: PhotoAPIError.notFound),
            PhotoAPIError.notFound.errorDescription
        )
    }

    // MARK: - Helpers

    private func makeEngine(
        reader: DeletionQueueReading,
        writer: DeletionQueueWriting,
        api: PhotoApiFetching
    ) -> PhotoDeletionEngine {
        PhotoDeletionEngine(api: api, deletionQueueReader: reader, deletionQueueWriter: writer)
    }

    private func item(fileId: String) -> DeletionItemSnapshot {
        DeletionItemSnapshot(
            fileId: fileId,
            driveId: 1,
            localIdentifier: "",
            state: .queued,
            enqueuedAt: Date(),
            attemptCount: 0,
            lastAttemptAt: nil,
            nextRetryAt: nil,
            lastErrorReason: ""
        )
    }
}

private actor ProgressCollector {
    var updates: [DeletionProgress] = []
    func record(_ progress: DeletionProgress) { updates.append(progress) }
}

// MARK: - Fakes

private final class FakeDeletionQueueReader: DeletionQueueReading {
    var items: [DeletionItemSnapshot] = []
    func allDeletions() throws -> [DeletionItemSnapshot] { items }
    func nextDeletable(now: Date, limit: Int?) throws -> [DeletionItemSnapshot] { items }
    func deletionItem(fileId: String) throws -> DeletionItemSnapshot? {
        items.first { $0.fileId == fileId }
    }

    func pendingDeletionFileIds() throws -> Set<String> { Set(items.map(\.fileId)) }
}

private final class FakeDeletionQueueWriter: DeletionQueueWriting {
    var markedDeleting: [String] = []
    var markedCompleted: [String] = []
    var markedFailedTransient: [String] = []
    var markedFailedPermanent: [String] = []
    var resetOrphanedCallCount = 0

    func enqueueDeletion(fileId: String, driveId: Int, localIdentifier: String) async throws {}
    func enqueueDeletions(_ requests: [DeletionRequest]) async throws {}
    func markDeleting(fileId: String) async throws { markedDeleting.append(fileId) }
    func markDeletionCompleted(fileId: String) async throws { markedCompleted.append(fileId) }
    func markDeletionFailedTransient(fileId: String, reason: String, nextRetryAt: Date) async throws {
        markedFailedTransient.append(fileId)
    }

    func markDeletionFailedPermanent(fileId: String, reason: String) async throws {
        markedFailedPermanent.append(fileId)
    }

    func cancelDeletion(fileId: String) async throws {}
    func requeueDeletion(fileId: String) async throws {}
    func resetOrphanedDeletions() async throws -> Int { resetOrphanedCallCount += 1; return 0 }
}

/// Fake d'API minimal — seul `deleteFile` est exercé par le moteur de suppression.
private final class FakeDeletionApi: PhotoApiFetching {
    var deletedFileIds: [String] = []
    var deleteFileError: Error?

    func deleteFile(driveId: Int, fileId: String) async throws {
        if let deleteFileError { throw deleteFileError }
        deletedFileIds.append(fileId)
    }

    // Méthodes non utilisées par les tests de suppression.
    func listFolder(driveId: Int, folderId: String, cursor: String?, limit: Int) async throws -> FilePage {
        throw PhotoAPIError.invalidResponse
    }

    func upload(
        driveId: Int,
        folderId: String,
        fileURL: URL,
        fileName: String,
        createdAt: Date,
        mimeType: String,
        clientToken: String
    ) async throws -> RemoteFileDTO {
        throw PhotoAPIError.invalidResponse
    }

    func createDirectory(driveId: Int, name: String, parentId: String) async throws -> RemoteDirectoryDTO {
        throw PhotoAPIError.invalidResponse
    }

    func listDrives() async throws -> [RemoteDriveDTO] { [] }
    func listCategories(driveId: Int) async throws -> [RemoteCategoryDTO] { [] }
    func createCategory(driveId: Int, name: String, color: String?) async throws -> RemoteCategoryDTO {
        throw PhotoAPIError.invalidResponse
    }

    func updateCategory(driveId: Int, categoryId: Int, name: String?, color: String?) async throws -> RemoteCategoryDTO {
        throw PhotoAPIError.invalidResponse
    }

    func deleteCategory(driveId: Int, categoryId: Int) async throws {}
    func addCategoryToFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws {}
    func removeCategoryFromFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws {}
    func listCategoryFiles(driveId: Int, categoryId: Int, cursor: String?, limit: Int) async throws -> FilePage {
        throw PhotoAPIError.invalidResponse
    }

    func thumbnailData(driveId: Int, fileId: String) async throws -> Data { Data() }
    func previewData(driveId: Int, fileId: String, width: Int?, height: Int?, quality: Int?) async throws -> Data {
        Data()
    }

    func downloadFile(driveId: Int, fileId: String) async throws -> URL { throw PhotoAPIError.invalidResponse }
    func playbackURL(driveId: Int, fileId: String) async throws -> URL { throw PhotoAPIError.invalidResponse }
    func downloadURL(driveId: Int, fileId: String) -> URL {
        Endpoint.download(driveId: driveId, fileId: fileId).url
    }

    func previewURL(driveId: Int, fileId: String) -> URL {
        Endpoint.preview(driveId: driveId, fileId: fileId).url
    }

    func fileInfo(driveId: Int, fileId: String) async throws -> RemoteFileDetailDTO {
        throw PhotoAPIError.invalidResponse
    }
}
