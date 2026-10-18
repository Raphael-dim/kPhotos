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

final class MediaIndexUploadTransportTests: XCTestCase {
    override func tearDown() { IndexUploadProtocol.handler = nil; super.tearDown() }
    private func api() -> PhotoApiFetcher {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IndexUploadProtocol.self]
        return PhotoApiFetcher(configuration: config)
    }

    private func index() -> MediaLibraryIndex {
        MediaLibraryIndex(driveId: 7, rootId: "root", totalMedia: 0, pending: 0, failed: 0, records: [])
    }

    func testCacheUploadIsByteVerifiedAndUsesOnlyOwnedFolder() async throws {
        var uploaded = Data(); var uploads = 0
        IndexUploadProtocol.handler = { request in
            let path = try (XCTUnwrap(request.url)).path
            if path.hasSuffix("/root/files") {
                return try Self.json([
                    "data": [["id": "cache-folder", "name": ".kphotos-index", "type": "dir"]],
                    "has_more": false
                ])
            }
            if path.hasSuffix("/upload") {
                uploads += 1
                let items = try (XCTUnwrap(XCTUnwrap(URLComponents(
                    url: XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )).queryItems))
                let query = try Dictionary(uniqueKeysWithValues: items.map { try ($0.name, XCTUnwrap($0.value)) })
                XCTAssertEqual(query["directory_id"], "cache-folder"); XCTAssertEqual(query["file_name"], "index-ios-test.json")
                XCTAssertEqual(query["conflict"], "error"); XCTAssertEqual(query["client_token"], "stable-token")
                uploaded = try Self.body(request)
                return try Self.json([
                    "data": [
                        "id": "cache-id",
                        "name": "index-ios-test.json",
                        "type": "file",
                        "size": uploaded.count
                    ]
                ])
            }
            if path
                .hasSuffix("/download") {
                return IndexUploadResponse(status: 302, headers: ["Location": "https://synthetic.invalid/cache"], body: Data())
            }
            XCTAssertEqual(request.url?.host, "synthetic.invalid")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return IndexUploadResponse(status: 200, headers: ["Content-Length": String(uploaded.count)], body: uploaded)
        }
        let saved = try await api().saveMediaIndex(
            index(),
            name: "index-ios-test.json",
            previous: nil,
            clientToken: "stable-token"
        )
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(saved.sha256, SHA256.hash(data: uploaded).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try MediaLibraryIndex.decode(uploaded, driveId: 7, rootId: "root").cacheFolderId, "cache-folder")
    }

    func testChangedCacheCannotBeOverwrittenAndOriginalNamesAreRejected() async throws {
        var uploads = 0
        IndexUploadProtocol.handler = { request in
            let path = try (XCTUnwrap(request.url)).path
            if path.hasSuffix("/root/files") {
                return try Self.json([
                    "data": [["id": "cache-folder", "name": ".kphotos-index", "type": "dir"]],
                    "has_more": false
                ])
            }
            if path.hasSuffix("/cache-id") { return try Self.json([
                "data": [
                    "id": "cache-id",
                    "name": "index-ios-test.json",
                    "parent_id": "cache-folder"
                ]
            ]) }
            if path
                .hasSuffix("/download") {
                return IndexUploadResponse(status: 302, headers: ["Location": "https://synthetic.invalid/cache"], body: Data())
            }
            if request.url?
                .host ==
                "synthetic.invalid" {
                return IndexUploadResponse(status: 200, headers: ["Content-Length": "7"], body: Data("changed".utf8))
            }
            uploads += 1; throw PhotoAPIError.invalidResponse
        }
        let previous = MediaIndexUploadState(
            fileId: "cache-id",
            folderId: "cache-folder",
            name: "index-ios-test.json",
            sha256: String(repeating: "a", count: 64),
            fingerprint: ""
        )
        do { _ = try await api().saveMediaIndex(
            index(),
            name: "index-ios-test.json",
            previous: previous,
            clientToken: "stable-token"
        ); XCTFail("Must preserve changed bytes") } catch { XCTAssertEqual(error as? PhotoAPIError, .invalidResponse) }
        do { _ = try await api().saveMediaIndex(
            index(),
            name: "original.jpg",
            previous: nil,
            clientToken: "stable-token"
        ); XCTFail("Must reject original name") } catch { XCTAssertEqual(error as? PhotoAPIError, .invalidResponse) }
        XCTAssertEqual(uploads, 0)
    }

    private static func json(_ object: Any) throws -> IndexUploadResponse {
        try IndexUploadResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let size = stream.read(&buffer, maxLength: buffer.count)
            if size < 0 { throw PhotoAPIError.invalidResponse }
            if size == 0 { break }; bytes.append(contentsOf: buffer.prefix(size))
        }
        return bytes
    }
}

private struct IndexUploadResponse {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class IndexUploadProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> IndexUploadResponse)?
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response = try XCTUnwrap(Self.handler)(request)
            try client?.urlProtocol(
                self,
                didReceive: XCTUnwrap(HTTPURLResponse(
                    url: XCTUnwrap(request.url),
                    statusCode: response.status,
                    httpVersion: nil,
                    headerFields: response.headers
                )),
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: response.body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
