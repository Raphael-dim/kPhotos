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
@testable import kPhotosCore
import XCTest

final class UploadTransportTests: XCTestCase {
    override func tearDown() {
        StubKDriveProtocol.handler = nil
        StubKDriveProtocol.rawData = nil
        StubKDriveProtocol.statusCode = 200
        StubKDriveProtocol.headers = ["Content-Type": "application/json"]
        super.tearDown()
    }

    func testLargeUploadUsesTwoHashedChunksAndPreservesCaptureDate() async throws {
        let fixture = try UploadFixture(size: PhotoApiFetcher.chunkSize + 7)
        defer { fixture.cleanup() }
        var chunks: [Int] = []
        var starts = 0
        var finishes = 0
        StubKDriveProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let path = request.url!.path
            if path.hasSuffix("/start") {
                starts += 1
                let body = try Self.jsonBody(request)
                XCTAssertEqual(body["total_size"] as? Int, fixture.size)
                XCTAssertEqual(body["total_chunks"] as? Int, 2)
                XCTAssertEqual(body["created_at"] as? Int, 123_456_789)
                XCTAssertEqual(body["conflict"] as? String, "error")
                return Self.startResponse()
            }
            if path.hasSuffix("/chunk") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let params = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
                let number = Int(params["chunk_number"]!)!
                let data = try Self.body(request)
                XCTAssertEqual(data.count, number == 1 ? PhotoApiFetcher.chunkSize : 7)
                XCTAssertEqual(params["chunk_size"], String(data.count))
                XCTAssertEqual(
                    params["chunk_hash"],
                    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                chunks.append(number)
                return ["result": "success", "data": ["result": true]]
            }
            XCTAssertTrue(path.hasSuffix("/finish"))
            finishes += 1
            XCTAssertEqual(try Self.jsonBody(request)["created_at"] as? Int, 123_456_789)
            return Self.finishResponse(size: fixture.size)
        }
        let file = try await api().upload(
            driveId: 7,
            folderId: "42",
            fileURL: fixture.url,
            fileName: "video.mov",
            createdAt: Date(timeIntervalSince1970: 123_456_789),
            mimeType: "video/quicktime",
            clientToken: fixture.clientToken
        )
        XCTAssertEqual(file.id, "123")
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(chunks, [1, 2])
        XCTAssertEqual(finishes, 1)
        XCTAssertNil(try ChunkSessionStorage.read(fixture.key))
    }

    func testInterruptedUploadResumesAfterLastAcknowledgedChunk() async throws {
        let fixture = try UploadFixture(size: PhotoApiFetcher.chunkSize + 7)
        defer { fixture.cleanup() }
        try ChunkSessionStorage.save(
            ChunkUploadSession(
                token: "session",
                uploadURL: URL(string: "https://upload.infomaniak.com")!,
                startedAt: Date(),
                nextChunk: 2
            ),
            key: fixture.key
        )
        var chunks = 0
        StubKDriveProtocol.handler = { request in
            XCTAssertFalse(request.url!.path.hasSuffix("/start"), "A live session must be resumed")
            if request.url!.path.hasSuffix("/chunk") {
                chunks += 1
                let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(params.first { $0.name == "chunk_number" }?.value, "2")
                XCTAssertEqual(try Self.body(request).count, 7)
                return ["result": "success", "data": ["result": true]]
            }
            return Self.finishResponse(size: fixture.size)
        }
        _ = try await api().upload(
            driveId: 7,
            folderId: "42",
            fileURL: fixture.url,
            fileName: "video.mov",
            createdAt: Date(timeIntervalSince1970: 123_456_789),
            mimeType: "video/quicktime",
            clientToken: fixture.clientToken
        )
        XCTAssertEqual(chunks, 1)
        XCTAssertNil(try ChunkSessionStorage.read(fixture.key))
    }

    func testFalseFinishResultCannotBeReportedAsUploaded() async throws {
        let fixture = try UploadFixture(size: 7)
        defer { fixture.cleanup() }
        StubKDriveProtocol.handler = { request in
            if request.url!.path.hasSuffix("/start") { return Self.startResponse() }
            if request.url!.path.hasSuffix("/chunk") { return ["result": "success", "data": ["result": true]] }
            return ["result": "success", "data": ["result": false]]
        }
        do {
            _ = try await api().uploadChunked(
                driveId: 7,
                folderId: "42",
                fileURL: fixture.url,
                fileName: "video.mov",
                createdAt: Date(),
                totalSize: 7,
                clientToken: fixture.clientToken
            )
            XCTFail("Failed finalization must not become a successful backup")
        } catch { XCTAssertTrue(error is BackupSafetyError) }
        XCTAssertEqual(try ChunkSessionStorage.read(fixture.key)?.nextChunk, 2)
    }

    func testMissingCursorCannotCommitAnIncompleteListing() async throws {
        StubKDriveProtocol.handler = { _ in ["result": "success", "data": [], "has_more": true] }
        do {
            _ = try await api().listFolder(driveId: 7, folderId: "42", cursor: nil, limit: 100)
            XCTFail("An incomplete page must fail")
        } catch { XCTAssertEqual(error as? PhotoAPIError, .invalidResponse) }
    }

    func testBackgroundQuotaLeavesCapacityAndDoesNotDelayNewVisibleWork() async throws {
        let budget = APIRequestBudget(interval: 0.001, burstLimit: 8, windowLimit: 8, window: 0.25, backgroundWindowLimit: 2)
        try await budget.wait(priority: 0); try await budget.wait(priority: 0)
        let background = Task { try await budget.wait(priority: 0) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        try await budget.wait(priority: 2)
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - start,
            0.12,
            "A background-only quota delay must wake for visible work"
        )
        background.cancel()
        do { try await background.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testVisibleBurstStillHonorsRollingRequestLimit() async throws {
        let budget = APIRequestBudget(interval: 0.001, burstLimit: 3, windowLimit: 3, window: 0.16)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< 3 {
            try await budget.wait(priority: 1)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.12, "First tiles should start together")
        try await budget.wait(priority: 1)
        XCTAssertGreaterThanOrEqual(
            ProcessInfo.processInfo.systemUptime - start,
            0.15,
            "Burst cannot exceed the rolling window limit"
        )
    }

    func testCanceledThumbnailWaitersDoNotLeaveFutureQuotaReservations() async throws {
        let budget = APIRequestBudget(interval: 0.08)
        try await budget.wait()
        let waiting = (0 ..< 40).map { _ in Task { try await budget.wait() } }
        try await Task.sleep(nanoseconds: 10_000_000)
        for task in waiting {
            task.cancel()
        }
        for task in waiting {
            do { try await task.value; XCTFail("Canceled work must not start") } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        let start = Date()
        try await budget.wait()
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "Canceled cells must not leave seconds of invisible work"
        )
    }

    func testAlreadyCanceledRequestNeverReachesTransport() async throws {
        StubKDriveProtocol.handler = { _ in
            XCTFail("Canceled requests must never reach the server")
            return ["result": "success", "data": []]
        }
        let fetcher = api()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fetcher.listFolder(driveId: 7, folderId: "42")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testVideoRedirectIsResolvedWithoutSendingTokenToPlayer() async throws {
        StubKDriveProtocol.rawData = Data() // The real API redirect has no response body.
        StubKDriveProtocol.statusCode = 302
        StubKDriveProtocol.headers = ["Location": "https://media.infomaniakusercontent.com/video.mov?signature=test"]
        StubKDriveProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/download"))
            return [:]
        }
        let url = try await api().playbackURL(driveId: 7, fileId: "123")
        XCTAssertEqual(url.host, "media.infomaniakusercontent.com")
        XCTAssertEqual(url.query, "signature=test")
    }

    func testVideoRedirectRejectsInsecureLocation() async throws {
        StubKDriveProtocol.statusCode = 302
        StubKDriveProtocol.headers = ["Location": "http://media.infomaniakusercontent.com/video.mov"]
        StubKDriveProtocol.handler = { _ in [:] }
        do { _ = try await api().playbackURL(driveId: 7, fileId: "123"); XCTFail("Must reject") } catch {
            XCTAssertEqual(error as? PhotoAPIError, .invalidResponse)
        }
    }

    func testFailedRemoteDeletionIsNotReportedAsSuccessful() async throws {
        StubKDriveProtocol.statusCode = 404
        StubKDriveProtocol.handler = { _ in ["result": "error"] }
        do { try await api().deleteFile(driveId: 7, fileId: "123"); XCTFail("Must fail") } catch {
            XCTAssertEqual(error as? PhotoAPIError, .notFound)
        }
    }

    private func api() -> PhotoApiFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubKDriveProtocol.self]
        return PhotoApiFetcher(configuration: config)
    }

    private static func startResponse() -> [String: Any] {
        ["result": "success", "data": ["result": true, "token": "session", "upload_url": "https://upload.infomaniak.com"]]
    }

    private static func finishResponse(size: Int) -> [String: Any] {
        ["result": "success", "data": ["result": true, "file": ["id": 123, "name": "video.mov", "size": size]]]
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body(request)) as? [String: Any])
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead == 0 { break }
            guard bytesRead > 0 else { throw stream.streamError ?? PhotoAPIError.invalidResponse }
            result.append(buffer, count: bytesRead)
        }
        return result
    }
}

private struct UploadFixture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
    let clientToken = UUID().uuidString
    let size: Int
    var key: String { MediaIntegrity.token("7:42:\(clientToken):\(size)") }
    init(size: Int) throws {
        self.size = size
        try Data(repeating: 0x61, count: size).write(to: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
        ChunkSessionStorage.remove(key)
    }
}

private final class StubKDriveProtocol: URLProtocol {
    static var rawData: Data?
    static var statusCode = 200
    static var headers = ["Content-Type": "application/json"]
    static var handler: ((URLRequest) throws -> [String: Any])?
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let body = try handler(request)
            let data = try Self.rawData ?? JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: Self.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
