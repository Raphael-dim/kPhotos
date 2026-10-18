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

import CoreGraphics
import Foundation
import ImageIO
@testable import kPhotosCore
import XCTest

final class OriginalImageMetadataReaderTests: XCTestCase {
    func testGPSBeyondFirstMiBIsReadAndCompleteMissingGPSIsNotAFailure() async throws {
        let bitmap = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(bitmap.makeImage()), [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.0,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let jpeg = bytes as Data
        var padded = Data(jpeg.prefix(2))
        for _ in 0 ..< 20 {
            padded.append(contentsOf: [0xFF, 0xE2, 0xFF, 0xFA]); padded.append(Data(repeating: 0, count: 65528))
        }
        padded.append(jpeg.dropFirst(2))
        XCTAssertGreaterThan(padded.count, 1_048_576)
        XCTAssertEqual(
            EmbeddedMediaMetadata.image(data: padded, complete: true)?.coordinate,
            MediaCoordinate(latitude: 48, longitude: 2)
        )
        OriginalReadProtocol.original = padded; OriginalReadProtocol.requests = 0
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OriginalReadProtocol.self]
        let metadata = try await OriginalImageMetadataReader(configuration: configuration)
            .read(url: XCTUnwrap(URL(string: "https://synthetic.invalid/image")))
        XCTAssertEqual(metadata.coordinate, MediaCoordinate(latitude: 48, longitude: 2))
        XCTAssertFalse(metadata.isPartial); XCTAssertGreaterThan(OriginalReadProtocol.requests, 1)
    }

    func testTruncatedJPEGHeaderCannotConfirmMissingGPS() throws {
        XCTAssertFalse(OriginalImageMetadataReader.hasCompleteJPEGHeader(Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 20, 1, 2])))
        XCTAssertTrue(OriginalImageMetadataReader.hasCompleteJPEGHeader(Data([0xFF, 0xD8, 0xFF, 0xDA])))
        XCTAssertFalse(OriginalImageMetadataReader.hasCompleteJPEGHeader(Data("not-an-image".utf8)))
        XCTAssertTrue(EmbeddedMediaMetadata().isPartial)
    }
}

private final class OriginalReadProtocol: URLProtocol {
    static var original = Data(); static var requests = 0
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { Self.requests += 1
            let range = try (XCTUnwrap(request.value(forHTTPHeaderField: "Range")))
            let maximum = try (XCTUnwrap(Int(XCTUnwrap(range.split(separator: "-").last)))) + 1
            let bytes = Self.original.prefix(maximum)
            let response = try (XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": String(bytes.count),
                    "Content-Range": "bytes 0-\(bytes.count - 1)/\(Self.original.count)"
                ]
            )))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
