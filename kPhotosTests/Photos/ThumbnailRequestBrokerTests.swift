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
@testable import kPhotosCore
import XCTest

final class ThumbnailRequestBrokerTests: XCTestCase {
    func testConcurrentConsumersShareRequestAndOneCancellationKeepsOtherConsumer() async throws {
        let api = ThumbnailAPI(); let broker = ThumbnailRequestBroker(api: api)
        let first = Task { try await broker.data(driveId: 7, fileId: "id", revision: "rev", priority: 1) }
        let second = Task { try await broker.data(driveId: 7, fileId: "id", revision: "rev", priority: 2) }
        try await Task.sleep(nanoseconds: 20_000_000); first.cancel()
        let bytes = try await second.value
        XCTAssertEqual(bytes, Data([1, 2, 3])); XCTAssertEqual(api.count, 1)
        do { _ = try await first.value; XCTFail("Canceled consumer must not receive data") } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLastConsumerCancellationCancelsRequestAndLaterRequestCanRestart() async throws {
        let api = ThumbnailAPI(); let broker = ThumbnailRequestBroker(api: api)
        let first = Task { try await broker.data(driveId: 7, fileId: "id", revision: "rev", priority: 2) }
        try await Task.sleep(nanoseconds: 20_000_000); first.cancel()
        do { _ = try await first.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await broker.data(driveId: 7, fileId: "id", revision: "new", priority: 2)
        XCTAssertEqual(api.count, 2)
    }
}

private final class ThumbnailAPI: LibraryTestAPI {
    private let lock = NSLock(); private var requests = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    private func increment() { lock.lock(); requests += 1; lock.unlock() }
    override func thumbnailData(driveId: Int, fileId: String) async throws -> Data {
        increment(); try await Task.sleep(nanoseconds: 100_000_000); return Data([1, 2, 3])
    }
}
