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

import Photos
import XCTest
@testable import kPhotosCore

final class PHAssetReaderMappingTests: XCTestCase {
    func testMap_translatesEveryAuthorizationStatus() {
        XCTAssertEqual(PHAssetReaderImpl.map(.notDetermined), .notDetermined)
        XCTAssertEqual(PHAssetReaderImpl.map(.restricted), .restricted)
        XCTAssertEqual(PHAssetReaderImpl.map(.denied), .denied)
        XCTAssertEqual(PHAssetReaderImpl.map(.authorized), .authorized)
        XCTAssertEqual(PHAssetReaderImpl.map(.limited), .limited)
    }
}

final class PhotoLibrarySummaryTests: XCTestCase {
    func testEmpty_isAllZero() {
        XCTAssertEqual(PhotoLibrarySummary.empty,
                       PhotoLibrarySummary(totalAssets: 0, photosCount: 0, videosCount: 0))
    }
}

final class AssetLocationTests: XCTestCase {
    func testEquatableAndHashable() {
        let a = AssetLocation(localIdentifier: "L1", latitude: 46.2, longitude: 6.1)
        let b = AssetLocation(localIdentifier: "L1", latitude: 46.2, longitude: 6.1)
        let c = AssetLocation(localIdentifier: "L2", latitude: 46.2, longitude: 6.1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
