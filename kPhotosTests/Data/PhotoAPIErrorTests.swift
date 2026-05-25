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

import XCTest
@testable import kPhotosCore

final class PhotoAPIErrorTests: XCTestCase {
    func testEveryCase_hasNonEmptyDescription() {
        let cases: [PhotoAPIError] = [
            .unauthorized,
            .rateLimited(retryAfter: 30),
            .rateLimited(retryAfter: nil),
            .notFound,
            .server(statusCode: 500, message: "oops"),
            .network(underlying: "down"),
            .decoding(underlying: "bad json"),
            .invalidResponse
        ]
        for error in cases {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) doit exposer un message")
        }
    }

    func testRateLimited_withRetryAfter_mentionsSeconds() {
        XCTAssertTrue(PhotoAPIError.rateLimited(retryAfter: 45).errorDescription!.contains("45"))
    }

    func testServer_mentionsStatusCodeAndMessage() {
        let description = PhotoAPIError.server(statusCode: 503, message: "maintenance").errorDescription!
        XCTAssertTrue(description.contains("503"))
        XCTAssertTrue(description.contains("maintenance"))
    }
}

/// `PhotoApiFetcher.isRetryable` décide quelles erreurs déclenchent un retry
/// automatique (réseau / 429 / 5xx). Une 4xx ne doit jamais être rejouée.
final class PhotoApiFetcherRetryTests: XCTestCase {
    func testRetryable_networkRateLimitedAnd5xx() {
        XCTAssertTrue(PhotoApiFetcher.isRetryable(PhotoAPIError.network(underlying: "x")))
        XCTAssertTrue(PhotoApiFetcher.isRetryable(PhotoAPIError.rateLimited(retryAfter: nil)))
        XCTAssertTrue(PhotoApiFetcher.isRetryable(PhotoAPIError.server(statusCode: 500, message: nil)))
        XCTAssertTrue(PhotoApiFetcher.isRetryable(PhotoAPIError.server(statusCode: 599, message: nil)))
    }

    func testNotRetryable_4xxAndDecodingAndUnknown() {
        XCTAssertFalse(PhotoApiFetcher.isRetryable(PhotoAPIError.unauthorized))
        XCTAssertFalse(PhotoApiFetcher.isRetryable(PhotoAPIError.notFound))
        XCTAssertFalse(PhotoApiFetcher.isRetryable(PhotoAPIError.server(statusCode: 400, message: nil)))
        XCTAssertFalse(PhotoApiFetcher.isRetryable(PhotoAPIError.decoding(underlying: "x")))
        XCTAssertFalse(PhotoApiFetcher.isRetryable(PhotoAPIError.invalidResponse))
        XCTAssertFalse(PhotoApiFetcher.isRetryable(UploadError.cancelled))
    }
}

final class UploadErrorTests: XCTestCase {
    func testEveryCase_hasNonEmptyDescription() {
        let cases: [UploadError] = [
            .missingCreationDate,
            .fileNotReadable(path: "/tmp/x"),
            .chunkFailed(index: 3, underlying: "io"),
            .quotaExceeded,
            .cancelled
        ]
        for error in cases {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) doit exposer un message")
        }
    }

    func testChunkFailed_mentionsIndex() {
        XCTAssertTrue(UploadError.chunkFailed(index: 7, underlying: "io").errorDescription!.contains("7"))
    }
}

final class SyncErrorTests: XCTestCase {
    func testEveryCase_hasNonEmptyDescription() {
        let cases: [SyncError] = [.noPhotoLibraryAccess, .checkpointCorrupted, .backgroundBudgetExhausted]
        for error in cases {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) doit exposer un message")
        }
    }
}
