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
import UIKit
import XCTest

@MainActor
final class ViewerTransitionTests: XCTestCase {
    func testVerticalDragIsLeftToInteractiveDismissal() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native zoom requires iOS 18") }
        let coordinator = ViewerPagingGesture.Coordinator(isEnabled: true)
        let pan = TestPan(velocity: CGPoint(x: 20, y: 300))
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
    }

    func testHorizontalDragPagesInBothDirections() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native zoom requires iOS 18") }
        let coordinator = ViewerPagingGesture.Coordinator(isEnabled: true)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(TestPan(velocity: CGPoint(x: -300, y: 20))))
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(TestPan(velocity: CGPoint(x: 300, y: -20))))
    }

    func testZoomedPhotoKeepsItsOwnPanGesture() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native zoom requires iOS 18") }
        let coordinator = ViewerPagingGesture.Coordinator(isEnabled: false)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(TestPan(velocity: CGPoint(x: 300, y: 20))))
        coordinator.isEnabled = true
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(TestPan(velocity: CGPoint(x: 300, y: 20))))
    }

    func testStationaryOrAmbiguousDragDoesNotClaimPaging() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native zoom requires iOS 18") }
        let coordinator = ViewerPagingGesture.Coordinator(isEnabled: true)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(TestPan(velocity: .zero)))
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(TestPan(velocity: CGPoint(x: 40, y: 40))))
    }

    func testVideoControlsKeepTheirTouches() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native zoom requires iOS 18") }
        let coordinator = ViewerPagingGesture.Coordinator(isEnabled: true)
        let slider = UISlider()
        let thumb = UIView()
        slider.addSubview(thumb)
        XCTAssertFalse(coordinator.gestureRecognizer(UIPanGestureRecognizer(), shouldReceive: TestTouch(view: thumb)))
        XCTAssertTrue(coordinator.gestureRecognizer(UIPanGestureRecognizer(), shouldReceive: TestTouch(view: UIView())))
    }

    func testSyncedTileUsesCloudIdentityEvenWhenItsGalleryIdentityIsLocal() {
        let item = tile(localIdentifier: "local-asset", cloudFileId: "remote-file")
        XCTAssertEqual(item.viewerTransitionID, "cloud-remote-file")
    }

    func testCloudOnlyTileUsesTheSameTransitionIdentity() {
        let item = tile(localIdentifier: nil, cloudFileId: "remote-file")
        XCTAssertEqual(item.viewerTransitionID, "cloud-remote-file")
    }

    func testLocalTileMatchesLocalViewerIdentity() {
        let asset = LocalAssetSnapshot(localIdentifier: "local-asset", takenAt: .distantPast, isVideo: false)
        let item = tile(localIdentifier: asset.localIdentifier, cloudFileId: nil)
        XCTAssertEqual(item.viewerTransitionID, ViewerMedia.local(asset).id)
    }

    private func tile(localIdentifier: String?, cloudFileId: String?) -> GalleryItem {
        GalleryItem(
            id: localIdentifier ?? "cloud-only-gallery-id",
            takenAt: .distantPast,
            isVideo: false,
            localAssetIdentifier: localIdentifier,
            cloudFileId: cloudFileId,
            cloudDriveId: cloudFileId == nil ? nil : 7,
            syncState: cloudFileId == nil ? .localOnly : .synced
        )
    }
}

private final class TestPan: UIPanGestureRecognizer {
    private let testVelocity: CGPoint

    init(velocity: CGPoint) {
        self.testVelocity = velocity
        super.init(target: nil, action: nil)
    }

    override func velocity(in view: UIView?) -> CGPoint { testVelocity }
}

private final class TestTouch: UITouch {
    private let testView: UIView

    init(view: UIView) {
        self.testView = view
        super.init()
    }

    override var view: UIView? { testView }
}
