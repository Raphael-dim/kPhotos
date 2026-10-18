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

import kPhotosCore
@testable import kPhotosFeatures
import XCTest

final class PlacePreparationStatusTests: XCTestCase {
    func testFullProcessingWithoutErrorsIsComplete() {
        let result = PlacePreparationStatus(progress: .init(completed: 10, total: 10))
        XCTAssertEqual(result.phase, .complete)
    }

    func testTerminalFailuresAndPartialReadsAreNotComplete() {
        XCTAssertEqual(PlacePreparationStatus(progress: .init(completed: 10, total: 10, failed: 1)).phase, .attention)
        XCTAssertEqual(PlacePreparationStatus(progress: .init(completed: 10, total: 10, limited: 1)).phase, .attention)
    }

    func testIdleIncompletePreparationIsWaitingAndUnknownIsChecking() {
        XCTAssertEqual(PlacePreparationStatus(progress: .init(completed: 3, total: 10)).phase, .waiting)
        XCTAssertEqual(PlacePreparationStatus(progress: .init()).phase, .checking)
        XCTAssertNil(PlacePreparationStatus(progress: .init()).fraction)
    }

    func testManualPauseIsDistinctFromWaitingForNetwork() {
        var progress = MetadataIndexProgress(completed: 3, total: 10); progress.isPaused = true
        XCTAssertEqual(PlacePreparationStatus(progress: progress).phase, .paused)
        XCTAssertEqual(PlacePreparationStatus(progress: progress).fraction, 0.3)
    }
}
