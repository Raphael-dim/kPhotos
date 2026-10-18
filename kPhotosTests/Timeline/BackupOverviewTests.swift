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

import Foundation
@testable import kPhotosCore
@testable import kPhotosFeatures
import XCTest

final class BackupOverviewTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var asset: LocalAssetSnapshot { LocalAssetSnapshot(localIdentifier: "local", takenAt: date, isVideo: false) }

    private func photo(drive: Int = 7) -> PhotoSnapshot {
        var photo = PhotoSnapshot(
            id: "cloud",
            driveId: drive,
            localIdentifier: "local",
            name: "photo.heic",
            takenAt: date,
            uploadedAt: date,
            mimeType: "image/heic",
            size: 100,
            isVideo: false,
            duration: 0,
            albumIds: [],
            syncStatus: .synced,
            isFavorite: false
        )
        photo.libraryRootId = "root"; photo.backupComplete = true
        return photo
    }

    private func queued(_ state: BackupItemState) -> BackupItemSnapshot {
        BackupItemSnapshot(
            localIdentifier: "local",
            state: state,
            clientToken: "synthetic",
            enqueuedAt: date,
            creationDate: date,
            isVideo: false,
            attemptCount: 1,
            lastAttemptAt: date,
            nextRetryAt: nil,
            lastErrorReason: ""
        )
    }

    private func overview(
        assets: [LocalAssetSnapshot]? = nil,
        photos: [PhotoSnapshot] = [],
        state: BackupItemState? = nil,
        uploads: [String: UploadState] = [:],
        authorization: PhotoLibraryAuthorization = .authorized,
        checked: Bool = true,
        settings: SyncSettingsSnapshot = .defaults,
        error: String? = nil
    ) -> BackupOverview {
        BackupOverview.make(BackupOverviewInput(
            assets: assets ?? [asset],
            photos: photos,
            queue: state.map { ["local": queued($0)] } ?? [:],
            uploads: uploads,
            driveId: 7,
            rootId: "root",
            settings: settings,
            authorization: authorization,
            checked: checked,
            running: false,
            error: error
        ))
    }

    func testVerifiedOriginalsGiveUpToDateRegardlessOfOldQueueState() {
        let result = overview(photos: [photo()], state: .queued)
        XCTAssertEqual(result.phase, .upToDate)
        XCTAssertEqual(result.verified, 1); XCTAssertEqual(result.remaining, 0)
        XCTAssertTrue(result.items.isEmpty); XCTAssertEqual(result.lastBackupAt, date)
    }

    func testCompletedQueueAloneNeverProvesBackup() {
        let result = overview(state: .completed)
        XCTAssertEqual(result.phase, .waiting)
        XCTAssertEqual(result.items.first?.state, .unverified)
        XCTAssertEqual(result.verified, 0)
    }

    func testOldOrIncompleteCloudRecordDoesNotProveBackup() {
        var incomplete = photo(); incomplete.backupComplete = false
        XCTAssertEqual(overview(photos: [incomplete]).phase, .waiting)
        var unavailable = photo(); unavailable.isAvailable = false
        XCTAssertEqual(overview(photos: [unavailable]).phase, .waiting)
    }

    func testAnotherDriveOrFolderDoesNotProveBackup() {
        XCTAssertEqual(overview(photos: [photo(drive: 8)]).verified, 0)
        var other = photo(); other.libraryRootId = "other"
        XCTAssertEqual(overview(photos: [other]).verified, 0)
    }

    func testEditedLocalAssetInvalidatesEarlierVerification() {
        var edited = asset; edited.modifiedAt = date
        XCTAssertEqual(overview(assets: [edited], photos: [photo()]).phase, .waiting)
        var current = photo(); current.localModifiedAt = date
        XCTAssertEqual(overview(assets: [edited], photos: [current]).phase, .upToDate)
    }

    func testNewLocalPhotoInvalidatesUpToDate() {
        let new = LocalAssetSnapshot(localIdentifier: "new", takenAt: date, isVideo: false)
        let result = overview(assets: [asset, new], photos: [photo()])
        XCTAssertEqual(result.phase, .waiting); XCTAssertEqual(result.remaining, 1)
    }

    func testOnlyActualRuntimeUploadsAppearAsActive() {
        XCTAssertEqual(overview(state: .uploading).phase, .waiting)
        XCTAssertTrue(overview(state: .uploading).active.isEmpty)
        let active = overview(uploads: ["local": .uploading(fraction: 0.4)])
        XCTAssertEqual(active.phase, .saving)
        XCTAssertEqual(active.active.first?.state, .uploading(0.4))
        XCTAssertEqual(overview(uploads: ["local": .completed]).verified, 0)
    }

    func testSkippedAndFailedRemainVisibleAndIncomplete() {
        XCTAssertEqual(overview(state: .skipped).phase, .attention)
        XCTAssertEqual(overview(state: .skipped).skipped, 1)
        XCTAssertEqual(overview(state: .failedPermanent).phase, .attention)
        XCTAssertEqual(overview(state: .failedPermanent).permanentFailures, 1)
        XCTAssertEqual(overview(state: .failedTransient).phase, .waiting)
        XCTAssertEqual(overview(state: .failedTransient).failed, 1)
    }

    func testLimitedPermissionDoesNotClaimEntireLibraryIsUpToDate() {
        XCTAssertEqual(overview(photos: [photo()], authorization: .limited).phase, .selectionComplete)
        XCTAssertEqual(overview(photos: [photo()], authorization: .denied).phase, .accessRequired)
    }

    func testMediaFilterCompletionIsExplicitlyLimitedToSelection() {
        let video = LocalAssetSnapshot(localIdentifier: "video", takenAt: date, isVideo: true)
        var settings = SyncSettingsSnapshot.defaults; settings.mediaFilter = .photos
        let result = overview(assets: [asset, video], photos: [photo()], settings: settings)
        XCTAssertEqual(result.phase, .selectionComplete); XCTAssertEqual(result.total, 1)
    }

    func testCheckingErrorsAndEmptyLibraryNeverClaimCompletion() {
        XCTAssertEqual(overview(photos: [photo()], checked: false).phase, .checking)
        XCTAssertEqual(overview(photos: [photo()], error: "synthetic").phase, .attention)
        XCTAssertEqual(overview(assets: []).phase, .empty)
        XCTAssertEqual(overview(assets: []).fraction, 0)
    }

    func testQueueUsesCaptureDateAndPreservesVideoKind() {
        let video = LocalAssetSnapshot(localIdentifier: "video", takenAt: date.addingTimeInterval(60), isVideo: true)
        let result = overview(assets: [asset, video])
        XCTAssertEqual(result.items.map(\.id), ["video", "local"])
        XCTAssertTrue(result.items[0].asset.isVideo)
    }
}
