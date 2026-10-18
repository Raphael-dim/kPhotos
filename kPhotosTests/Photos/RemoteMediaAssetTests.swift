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

import AVFoundation
import CoreVideo
import Foundation
@testable import kPhotosCore
import XCTest

final class RemoteMediaAssetTests: XCTestCase {
    func testVideoMetadataUsesBoundedHTTPSRangesWithoutPassingCredentialsToAVFoundation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeFixture(to: url)
        let original = try Data(contentsOf: url)
        var position = 0
        while position + 8 <= original.count {
            let size = original[position ..< position + 4].reduce(0) { ($0 << 8) | Int($1) }
            if String(data: original[position + 4 ..< position + 8], encoding: .ascii) == "moov" { break }
            guard size >= 8 else { throw PhotoAPIError.invalidResponse }
            position += size
        }
        XCTAssertLessThan(position, original.count)
        // Media offsets stay unchanged; metadata lies after a large, skippable QuickTime free atom.
        let paddingSize = 40 * 1024 * 1024
        var atomSize = UInt32(paddingSize).bigEndian
        var padding = withUnsafeBytes(of: &atomSize) { Data($0) }
        padding.append(Data("free".utf8))
        padding.append(Data(repeating: 0, count: paddingSize - 8))
        VideoRangeProtocol.bytes = original.prefix(position) + padding + original.suffix(from: position)
        VideoRangeProtocol.calls = 0
        VideoRangeProtocol.received = 0
        VideoRangeProtocol.largestOffset = 0
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [VideoRangeProtocol.self]
        let source = try RemoteMediaAsset(
            url: XCTUnwrap(URL(string: "https://synthetic.invalid/private-video")),
            configuration: configuration
        )
        defer { source.cancel() }
        let metadata = try await EmbeddedMediaMetadata.video(asset: source.asset)
        XCTAssertEqual(metadata.livePhotoContentIdentifier, "7142ABE5-762C-47C1-B1D6-92BF978C2152")
        XCTAssertEqual(metadata.readerVersion, 2)
        XCTAssertEqual(metadata.coordinate?.latitude ?? 0, 48.8566, accuracy: 0.00001)
        XCTAssertEqual(metadata.coordinate?.longitude ?? 0, 2.3522, accuracy: 0.00001)
        XCTAssertEqual(metadata.captureDate, ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
        XCTAssertGreaterThan(VideoRangeProtocol.calls, 0)
        XCTAssertGreaterThanOrEqual(VideoRangeProtocol.largestOffset, paddingSize)
        XCTAssertLessThan(VideoRangeProtocol.received, 2 * 1024 * 1024)
    }

    private func writeFixture(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.dataType = kCMMetadataBaseDataType_UTF8 as String
        location.value = "+48.8566+002.3522/" as NSString
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.dataType = kCMMetadataBaseDataType_UTF8 as String
        date.value = "2020-01-02T03:04:05Z" as NSString
        let contentIdentifier = AVMutableMetadataItem()
        contentIdentifier.identifier = .quickTimeMetadataContentIdentifier
        contentIdentifier.dataType = kCMMetadataBaseDataType_UTF8 as String
        contentIdentifier.value = "7142ABE5-762C-47C1-B1D6-92BF978C2152" as NSString
        writer.metadata = [location, date, contentIdentifier]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer),
            kCVReturnSuccess
        )
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        CVPixelBufferGetBaseAddress(pixel)?.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for _ in 0 ..< 100 {
            if input.isReadyForMoreMediaData { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(adaptor.append(pixel, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}

private final class VideoRangeProtocol: URLProtocol {
    static var bytes = Data(); static var calls = 0
    static var received = 0; static var largestOffset = 0
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        guard let header = request.value(forHTTPHeaderField: "Range"), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: PhotoAPIError.invalidResponse); return
        }
        let range = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        guard range.count == 2, let start = Int(range[0]), let requestedEnd = Int(range[1]) else {
            client?.urlProtocol(self, didFailWithError: PhotoAPIError.invalidResponse); return
        }
        let end = min(requestedEnd, Self.bytes.count - 1)
        guard start <= end else {
            client?.urlProtocol(self, didFailWithError: PhotoAPIError.invalidResponse); return
        }
        let chunk = Self.bytes.subdata(in: start ..< end + 1)
        Self.received += chunk.count
        Self.largestOffset = max(Self.largestOffset, start)
        guard let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Type": "video/quicktime", "Content-Length": String(chunk.count),
            "Content-Range": "bytes \(start)-\(end)/\(Self.bytes.count)"
        ]) else {
            client?.urlProtocol(self, didFailWithError: PhotoAPIError.invalidResponse); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: chunk); client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
