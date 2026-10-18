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
import ImageIO
@testable import kPhotosCore
@testable import kPhotosFeatures
import UIKit
import XCTest

final class GalleryPerformanceTests: XCTestCase {
    func testLargeImageIsDownsampledAndSurvivesDiskCacheReload() async throws {
        let bitmap = try XCTUnwrap(CGContext(
            data: nil,
            width: 2400,
            height: 1800,
            bitsPerComponent: 8,
            bytesPerRow: 2400 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let cg = try XCTUnwrap(bitmap.makeImage())
        let original = try XCTUnwrap(UIImage(cgImage: cg).jpegData(compressionQuality: 0.9))
        let image = await ThumbnailImageDecoder.decode(original)
        let decoded = try XCTUnwrap(image)
        XCTAssertEqual(decoded.cgImage?.width, 400)
        XCTAssertEqual(decoded.cgImage?.height, 300)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kphotos-cache-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = ThumbnailCache(directory: dir)
        try first.storeOnDisk(XCTUnwrap(decoded.jpegData(compressionQuality: 0.75)), forKey: "test")
        await ImageDiskBudget.waitForWrites()
        let second = ThumbnailCache(directory: dir)
        let loaded = await second.diskImageAsync(forKey: "test")
        XCTAssertEqual(loaded?.cgImage?.width, 400)
        XCTAssertEqual(loaded?.cgImage?.height, 300)
    }

    @MainActor
    func testLeavingTileReleasesItsImageAndReusesSharedCacheOnReturn() async throws {
        let bitmap = try XCTUnwrap(CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try UIImage(cgImage: XCTUnwrap(bitmap.makeImage()))
        let fileId = "cache-test-" + UUID().uuidString
        let key = "7-" + fileId
        ThumbnailCache.shared.store(image, forKey: key)
        let loader = ThumbnailLoader(driveId: 7, fileId: fileId)
        await loader.load()
        XCTAssertNotNil(loader.image)
        loader.releaseImage()
        XCTAssertNil(loader.image)
        XCTAssertNotNil(ThumbnailCache.shared.image(forKey: key))
        await loader.load()
        XCTAssertNotNil(loader.image)
    }

    @MainActor
    func testThumbnailRevisionGetsADifferentCacheKey() {
        let old = ThumbnailLoader.cacheKey(driveId: 7, fileId: "id", revision: "old")
        let new = ThumbnailLoader.cacheKey(driveId: 7, fileId: "id", revision: "new")
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(ThumbnailLoader.cacheKey(driveId: 7, fileId: "id", revision: ""), "7-id")
        XCTAssertNotEqual(old, ThumbnailLoader.cacheKey(driveId: 8, fileId: "id", revision: "old"))
    }

    func testOpeningKnownLibraryUsesCacheAndRefreshScheduleIsScoped() throws {
        let suite = "kphotos-refresh-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schedule = LibraryRefreshSchedule(defaults: defaults, interval: 900)
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertFalse(schedule.shouldRefresh(driveId: 7, rootId: "old", hasCache: true, now: now))
        XCTAssertFalse(schedule.shouldRefresh(driveId: 7, rootId: "old", hasCache: true, now: now.addingTimeInterval(300)))
        XCTAssertTrue(schedule.shouldRefresh(driveId: 7, rootId: "old", hasCache: true, now: now.addingTimeInterval(901)))
        XCTAssertTrue(schedule.shouldRefresh(driveId: 7, rootId: "new", hasCache: false, now: now))
        schedule.markSuccess(driveId: 7, rootId: "old", now: now.addingTimeInterval(900))
        XCTAssertFalse(schedule.shouldRefresh(driveId: 7, rootId: "old", hasCache: true, now: now.addingTimeInterval(1000)))
    }
}
