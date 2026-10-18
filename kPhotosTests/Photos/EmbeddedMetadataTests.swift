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
@testable import kPhotosFeatures
import RealmSwift
import XCTest

final class EmbeddedMetadataTests: XCTestCase {
    func testLivePhotoIdentifierComesFromAppleMakerNote() throws {
        let identifier = "7142ABE5-762C-47C1-B1D6-92BF978C2152"
        let metadata = EmbeddedMediaMetadata.image(properties: [
            kCGImagePropertyMakerAppleDictionary as String: ["17": identifier]
        ])
        XCTAssertEqual(metadata.livePhotoContentIdentifier, identifier)
        XCTAssertEqual(metadata.readerVersion, 2)
        XCTAssertNil(EmbeddedMediaMetadata.image(properties: [
            kCGImagePropertyMakerAppleDictionary as String: ["17": "not-an-identifier"]
        ]).livePhotoContentIdentifier)
    }

    func testExifCoordinatesRespectHemisphereAndValidateBounds() throws {
        let props: [String: Any] = [
            kCGImagePropertyGPSDictionary as String:
                [
                    kCGImagePropertyGPSLatitude as String: 12.5,
                    kCGImagePropertyGPSLatitudeRef as String: "S",
                    kCGImagePropertyGPSLongitude as String: 34.5,
                    kCGImagePropertyGPSLongitudeRef as String: "W"
                ]
        ]
        XCTAssertEqual(
            EmbeddedMediaMetadata.image(properties: props).coordinate,
            MediaCoordinate(latitude: -12.5, longitude: -34.5)
        )
        XCTAssertNil(EmbeddedMediaMetadata.image(properties: [
            kCGImagePropertyGPSDictionary as String:
                [kCGImagePropertyGPSLatitude as String: 12.5, kCGImagePropertyGPSLongitude as String: 34.5]
        ]).coordinate)
        XCTAssertNil(MediaCoordinate(latitude: 91, longitude: 0))
    }

    func testExifCaptureDateUsesOffsetWhenPresent() throws {
        let metadata = EmbeddedMediaMetadata.image(properties: [
            kCGImagePropertyExifDictionary as String:
                [kCGImagePropertyExifDateTimeOriginal as String: "2018:08:05 18:32:24", "OffsetTimeOriginal": "+02:00"]
        ])
        XCTAssertEqual(metadata.captureDate, ISO8601DateFormatter().date(from: "2018-08-05T16:32:24Z"))
        XCTAssertTrue(metadata.hasExplicitTimezone)
    }

    func testExifDateWithoutTimezoneIsExplicitlyUnconfirmed() throws {
        let metadata = EmbeddedMediaMetadata.image(properties: [
            kCGImagePropertyExifDictionary as String:
                [kCGImagePropertyExifDateTimeOriginal as String: "2018:08:05 18:32:24"]
        ])
        XCTAssertFalse(metadata.hasExplicitTimezone)
        XCTAssertEqual(metadata.rawCaptureDate, "2018:08:05 18:32:24")
        XCTAssertNotNil(metadata.captureDate)
    }

    func testQuickTimeISO6709WithAltitudeAndInvalidCoordinates() throws {
        XCTAssertEqual(
            EmbeddedMediaMetadata.iso6709("+46.1234-006.4321+004.500/"),
            MediaCoordinate(latitude: 46.1234, longitude: -6.4321)
        )
        XCTAssertNil(EmbeddedMediaMetadata.iso6709("+99.1234+006.4321/"))
        XCTAssertNil(EmbeddedMediaMetadata.iso6709("missing"))
    }

    func testOriginalJPEGHeaderProvidesExifInsteadOfPreviewMetadata() throws {
        let bitmap = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(bitmap.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        let props: [String: Any] = [
            kCGImagePropertyGPSDictionary as String:
                [
                    kCGImagePropertyGPSLatitude as String: 48.0,
                    kCGImagePropertyGPSLatitudeRef as String: "N",
                    kCGImagePropertyGPSLongitude as String: 2.0,
                    kCGImagePropertyGPSLongitudeRef as String: "E"
                ],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "SyntheticCamera"]
        ]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let metadata = try XCTUnwrap(EmbeddedMediaMetadata.image(data: bytes as Data))
        XCTAssertEqual(metadata.coordinate, MediaCoordinate(latitude: 48, longitude: 2))
        XCTAssertEqual(metadata.model, "SyntheticCamera")
        XCTAssertEqual(metadata.pixelWidth, 2)
        XCTAssertEqual(metadata.detectedImageType, "public.jpeg")
        let misleadingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("HEIC")
        defer { try? FileManager.default.removeItem(at: misleadingURL) }
        try (bytes as Data).write(to: misleadingURL)
        XCTAssertEqual(EmbeddedMediaMetadata.image(url: misleadingURL)?.detectedImageType, "public.jpeg")
    }

    func testMediaFilterAcceptsMissingMimeAndRefusesArchivesWithIncorrectMime() throws {
        XCTAssertTrue(EmbeddedMetadataIndexer.isMedia(makePhoto(name: "original.HEIC", mimeType: "application/octet-stream")))
        XCTAssertFalse(EmbeddedMetadataIndexer.isMedia(makePhoto(name: "metadata.zip", mimeType: "image/jpeg")))
        XCTAssertFalse(RemoteFileDTO.isSupportedMedia(name: "metadata.zip", mimeType: "image/jpeg"))
    }

    func testMetadataRoundTripsThroughRealmSnapshot() throws {
        var photo = makePhoto()
        var metadata = EmbeddedMediaMetadata()
        metadata.coordinate = MediaCoordinate(latitude: -12, longitude: 34)
        photo.embeddedMetadataJSON = try XCTUnwrap(String(data: JSONEncoder().encode(metadata), encoding: .utf8))
        photo.embeddedMetadataRevision = "revision"
        let snapshot = try PhotoSnapshot(PhotoManagerImpl.makePhoto(from: photo))
        XCTAssertEqual(snapshot.embeddedMetadata, metadata)
        XCTAssertEqual(snapshot.embeddedMetadataRevision, "revision")
    }

    @MainActor
    func testMetadataCacheSurvivesSameRevisionAndInvalidatesChangedOriginal() async throws {
        let configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString, objectTypes: [Photo.self])
        let held = try holdRealm(configuration)
        let manager = PhotoManagerImpl(realm: RealmAccessorImpl(configuration: configuration))
        var photo = makePhoto()
        photo.remoteRevision = "old"
        photo.libraryRootId = "root"
        try await manager.upsert(photo)
        var metadata = EmbeddedMediaMetadata()
        metadata.coordinate = MediaCoordinate(latitude: -12, longitude: 34)
        try await manager.updateEmbeddedMetadata(driveId: 7, fileId: photo.id, revision: "old", metadata: metadata)
        try await manager.upsertFromListing([photo])
        XCTAssertEqual(try manager.photo(byFileId: photo.id)?.embeddedMetadata, metadata)
        try await manager.commitListing([photo], driveId: 7, folderId: "root", fileIds: [photo.id], revisions: [photo.id: "old"])
        XCTAssertEqual(try manager.photo(byFileId: photo.id)?.embeddedMetadata, metadata)
        photo.remoteRevision = "new"
        try await manager.commitListing([photo], driveId: 7, folderId: "root", fileIds: [photo.id], revisions: [photo.id: "new"])
        XCTAssertNil(try manager.photo(byFileId: photo.id)?.embeddedMetadata)
        try await manager.updateEmbeddedMetadata(driveId: 7, fileId: photo.id, revision: "old", metadata: metadata)
        XCTAssertNil(try manager.photo(byFileId: photo.id)?.embeddedMetadata)
        held.refresh()
        XCTAssertEqual(held.objects(Photo.self).count, 1)
    }

    @MainActor
    func testMetadataForAnotherDriveCannotChangeStoredPhoto() async throws {
        let configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString, objectTypes: [Photo.self])
        let held = try holdRealm(configuration)
        let manager = PhotoManagerImpl(realm: RealmAccessorImpl(configuration: configuration))
        let photo = makePhoto()
        try await manager.upsert(photo)
        var metadata = EmbeddedMediaMetadata()
        metadata.coordinate = MediaCoordinate(latitude: -12, longitude: 34)
        try await manager.updateEmbeddedMetadata(driveId: 8, fileId: photo.id, revision: "", metadata: metadata)
        XCTAssertNil(try manager.photo(byFileId: photo.id)?.embeddedMetadata)
        held.refresh()
        XCTAssertEqual(held.objects(Photo.self).count, 1)
    }

    @MainActor
    func testMapAcceptsEmbeddedCloudGPSWithoutLocalPhotoAndRejectsLegacyGoogleGPS() throws {
        var photo = makePhoto()
        photo.coordinate = MediaCoordinate(latitude: -12, longitude: 34)
        photo.locationSource = "embedded"
        XCTAssertEqual(PhotoMapViewModel.makePoints(photos: [photo], localLocations: []).count, 1)
        photo.locationSource = "google"
        XCTAssertTrue(PhotoMapViewModel.makePoints(photos: [photo], localLocations: []).isEmpty)
    }

    private func holdRealm(_ configuration: Realm.Configuration) throws -> Realm {
        try Realm(configuration: configuration)
    }

    private func makePhoto(name: String = "old.jpg", mimeType: String = "image/jpeg") -> PhotoSnapshot {
        PhotoSnapshot(
            id: "test-photo",
            driveId: 7,
            localIdentifier: "",
            name: name,
            takenAt: Date(),
            uploadedAt: Date(),
            mimeType: mimeType,
            size: 10,
            isVideo: false,
            duration: 0,
            albumIds: [],
            syncStatus: .synced,
            isFavorite: false
        )
    }
}

private final class MetadataReadProtocol: URLProtocol {
    static var status = 206
    static var body = Data()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let headers = ["Content-Length": String(Self.body.count), "Content-Range": "bytes 0-\(Self.body.count - 1)/100"]
            let response = try (XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: Self.status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class BoundedMetadataReadTests: XCTestCase {
    private func reader(limit: Int) -> BoundedMediaRead {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataReadProtocol.self]
        return BoundedMediaRead(maximum: limit, configuration: configuration)
    }

    func testPartialOriginalReadIsBounded() async throws {
        MetadataReadProtocol.status = 206; MetadataReadProtocol.body = Data(repeating: 7, count: 16)
        let bytes = try await reader(limit: 32).read(url: XCTUnwrap(URL(string: "https://synthetic.invalid/original")))
        XCTAssertEqual(bytes.count, 16)
    }

    func testServerIgnoringRangeForLargeOriginalIsRejected() async throws {
        MetadataReadProtocol.status = 200; MetadataReadProtocol.body = Data(repeating: 7, count: 64)
        do {
            _ = try await reader(limit: 32).read(url: XCTUnwrap(URL(string: "https://synthetic.invalid/original")))
            XCTFail("Must reject a full download larger than the budget")
        } catch { XCTAssertEqual(error as? PhotoAPIError, .invalidResponse) }
    }

    func testOversizedRangeResponseIsRejected() async throws {
        MetadataReadProtocol.status = 206; MetadataReadProtocol.body = Data(repeating: 7, count: 64)
        do {
            _ = try await reader(limit: 32).read(url: XCTUnwrap(URL(string: "https://synthetic.invalid/original")))
            XCTFail("Must reject oversized range")
        } catch { XCTAssertEqual(error as? PhotoAPIError, .invalidResponse) }
    }

    func testCanceledReadCompletesWithoutNetworkWork() async throws {
        let task = Task {
            try await reader(limit: 32).read(url: XCTUnwrap(URL(string: "https://synthetic.invalid/original")))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
