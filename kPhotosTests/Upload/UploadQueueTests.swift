/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

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
import XCTest
@testable import kPhotosCore

/// File d'upload runtime in-memory — état éphémère superposé aux tuiles.
final class UploadQueueTests: XCTestCase {
    func testMark_storesStateByLocalIdentifier() {
        let queue = UploadQueueImpl()
        queue.mark(localIdentifier: "L1", state: .uploading(fraction: 0.5))
        XCTAssertEqual(queue.currentStates["L1"], .uploading(fraction: 0.5))
    }

    func testMark_emptyIdentifier_isIgnored() {
        let queue = UploadQueueImpl()
        queue.mark(localIdentifier: "", state: .pending)
        XCTAssertTrue(queue.currentStates.isEmpty)
    }

    func testMark_overwritesPreviousState() {
        let queue = UploadQueueImpl()
        queue.mark(localIdentifier: "L1", state: .pending)
        queue.mark(localIdentifier: "L1", state: .completed)
        XCTAssertEqual(queue.currentStates["L1"], .completed)
    }

    func testClearCompleted_dropsCompletedAndFailed_keepsActiveStates() {
        let queue = UploadQueueImpl()
        queue.mark(localIdentifier: "done", state: .completed)
        queue.mark(localIdentifier: "failed", state: .failed(reason: "boom"))
        queue.mark(localIdentifier: "uploading", state: .uploading(fraction: nil))
        queue.mark(localIdentifier: "pending", state: .pending)

        queue.clearCompleted()

        XCTAssertNil(queue.currentStates["done"])
        XCTAssertNil(queue.currentStates["failed"])
        XCTAssertEqual(queue.currentStates["uploading"], .uploading(fraction: nil))
        XCTAssertEqual(queue.currentStates["pending"], .pending)
    }

    func testStatesPublisher_emitsLatestSnapshotOnMark() {
        let queue = UploadQueueImpl()
        var received: [String: UploadState] = [:]
        let cancellable = queue.statesPublisher.sink { received = $0 }

        queue.mark(localIdentifier: "L1", state: .pending)
        XCTAssertEqual(received["L1"], .pending)

        cancellable.cancel()
    }
}
