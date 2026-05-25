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

import XCTest
@testable import kPhotosCore

/// Couvre le volet "suppression" du composer : projection
/// `DeletionItemState → GalleryItemSyncState` et priorité absolue de la
/// suppression sur l'état cloud/upload.
final class GalleryComposerDeletionTests: XCTestCase {
    private let composer = GalleryComposerImpl()
    private let cal = Calendar.iso8601

    func testCloudOnlyPhoto_withQueuedDeletion_marksDeletionPending() {
        let cloud = photo(fileId: "F1", localId: "")
        let deletion = deletionItem(fileId: "F1", state: .queued)

        let sections = composer.compose(
            localAssets: [],
            cloudPhotos: [cloud],
            backupItems: [:],
            deletionItems: ["F1": deletion],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .deletionPending)
    }

    func testCloudOnlyPhoto_withDeletingState_marksDeleting() {
        let cloud = photo(fileId: "F1", localId: "")
        let deletion = deletionItem(fileId: "F1", state: .deleting)

        let sections = composer.compose(
            localAssets: [],
            cloudPhotos: [cloud],
            backupItems: [:],
            deletionItems: ["F1": deletion],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .deleting)
    }

    func testFailedPermanentDeletion_surfacesTappableReason() {
        let cloud = photo(fileId: "F1", localId: "")
        let deletion = deletionItem(fileId: "F1", state: .failedPermanent, reason: "Droits insuffisants.")

        let sections = composer.compose(
            localAssets: [],
            cloudPhotos: [cloud],
            backupItems: [:],
            deletionItems: ["F1": deletion],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .deletionFailed(reason: "Droits insuffisants."))
    }

    func testFailedTransientDeletion_rendersAsDeletionPending_silentRetry() {
        // Comme côté upload : un échec transient ne doit pas alarmer l'utilisateur.
        let cloud = photo(fileId: "F1", localId: "")
        let deletion = deletionItem(fileId: "F1", state: .failedTransient, reason: "Réseau")

        let sections = composer.compose(
            localAssets: [],
            cloudPhotos: [cloud],
            backupItems: [:],
            deletionItems: ["F1": deletion],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .deletionPending)
    }

    func testDeletion_overridesSyncedCloudPhoto() {
        // L'utilisateur supprime une photo déjà sauvegardée : on n'affiche jamais
        // ".synced" derrière une suppression en cours — ce serait mensonger.
        let asset = LocalAssetSnapshot(localIdentifier: "L1", takenAt: date(), isVideo: false)
        let cloud = photo(fileId: "F1", localId: "L1")
        let deletion = deletionItem(fileId: "F1", state: .deleting)

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [cloud],
            backupItems: [:],
            deletionItems: ["F1": deletion],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .deleting)
    }

    func testDeletionState_completed_treatedAsCloudOnly() {
        // Cas anormal (l'engine purge normalement les `.completed`) : on ne crashe
        // pas, on retombe sur un état neutre.
        let item = deletionItem(fileId: "F1", state: .completed)
        XCTAssertEqual(GalleryComposerImpl.deletionState(from: item), .cloudOnly)
    }

    // MARK: - Helpers

    private func date() -> Date { Date(timeIntervalSince1970: 1_718_000_000) }

    private func photo(fileId: String, localId: String) -> PhotoSnapshot {
        PhotoSnapshot(
            id: fileId, driveId: 1, localIdentifier: localId, name: "\(fileId).jpg",
            takenAt: date(), uploadedAt: date(), mimeType: "image/jpeg", size: 0,
            isVideo: false, duration: 0, albumIds: [], syncStatus: .synced, isFavorite: false
        )
    }

    private func deletionItem(fileId: String,
                              state: DeletionItemState,
                              reason: String = "") -> DeletionItemSnapshot {
        DeletionItemSnapshot(
            fileId: fileId, driveId: 1, localIdentifier: "", state: state,
            enqueuedAt: date(), attemptCount: 0, lastAttemptAt: nil,
            nextRetryAt: nil, lastErrorReason: reason
        )
    }
}
