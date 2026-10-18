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

@testable import kPhotosFeatures
import UIKit
import XCTest

@MainActor
final class TimelineFastScrollerTests: XCTestCase {
    func testScrollableRailClaimsTheWholeRightEdge() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 2400)
        let rail = FastScrollerControl(frame: CGRect(x: 276, y: 0, width: 44, height: 600))
        rail.attach(to: scrollView)

        XCTAssertTrue(rail.isUserInteractionEnabled)
        XCTAssertTrue(rail.hitTest(CGPoint(x: 2, y: 300), with: nil) === rail)
        XCTAssertTrue(rail.hitTest(CGPoint(x: 42, y: 300), with: nil) === rail)
    }

    func testRailLetsTouchesThroughWhenThereIsNothingToScroll() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.contentSize = CGSize(width: 320, height: 400)
        let rail = FastScrollerControl(frame: CGRect(x: 276, y: 0, width: 44, height: 600))
        rail.attach(to: scrollView)

        XCTAssertFalse(rail.isUserInteractionEnabled)
        XCTAssertNil(rail.hitTest(CGPoint(x: 22, y: 300), with: nil))

        scrollView.contentSize = CGSize(width: 320, height: 1800)
        XCTAssertTrue(rail.isUserInteractionEnabled)
    }
}
