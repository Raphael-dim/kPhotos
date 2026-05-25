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

/// Tests purs du composer — logique de fusion locale/cloud + résolution d'état.
/// Pas de Realm, pas de PhotoKit, pas de réseau.
final class GalleryComposerTests: XCTestCase {
    private let composer = GalleryComposerImpl()
    private let cal = Calendar.iso8601

    func testLocalOnly_whenAssetHasNoCloudCounterpart_marksLocalOnly() {
        let asset = LocalAssetSnapshot(localIdentifier: "L1",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)

        let sections = composer.compose(localAssets: [asset],
                                        cloudPhotos: [],
                                        uploadStates: [:],
                                        calendar: cal)

        XCTAssertEqual(sections.count, 1)
        let item = sections[0].items[0]
        XCTAssertEqual(item.syncState, .localOnly)
        XCTAssertEqual(item.localAssetIdentifier, "L1")
        XCTAssertNil(item.cloudFileId)
    }

    func testSynced_whenLocalAssetMatchesCloudPhoto_marksSynced() {
        let asset = LocalAssetSnapshot(localIdentifier: "L2",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let cloud = photo(fileId: "F2", localId: "L2", date: date("2024-06-15"))

        let sections = composer.compose(localAssets: [asset],
                                        cloudPhotos: [cloud],
                                        uploadStates: [:],
                                        calendar: cal)

        let item = sections[0].items[0]
        XCTAssertEqual(item.syncState, .synced)
        XCTAssertEqual(item.cloudFileId, "F2")
        XCTAssertEqual(item.id, "L2", "Un asset synced garde son ID local — stabilité aux transitions")
    }

    func testCloudOnly_whenCloudPhotoHasNoLocalCounterpart_marksCloudOnly() {
        let cloud = photo(fileId: "F3", localId: "", date: date("2024-05-10"))

        let sections = composer.compose(localAssets: [],
                                        cloudPhotos: [cloud],
                                        uploadStates: [:],
                                        calendar: cal)

        let item = sections[0].items[0]
        XCTAssertEqual(item.syncState, .cloudOnly)
        XCTAssertEqual(item.id, "cloud-F3")
    }

    func testUploadingState_overridesPersistedSyncState() {
        // Cas où le runtime upload est plus à jour que ce que Realm a vu :
        // l'asset n'a pas encore de Photo cloud, mais on est en train de l'uploader.
        let asset = LocalAssetSnapshot(localIdentifier: "L4",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [],
            uploadStates: ["L4": .uploading(fraction: 0.42)],
            calendar: cal
        )
        let item = sections[0].items[0]
        XCTAssertEqual(item.syncState, .uploading(fraction: 0.42))
    }

    func testRuntimeFailedState_ignored_truthComesFromBackupItem() {
        // Le composer ignore désormais `UploadState.failed` (transient, peu fiable
        // entre sessions). La source de vérité d'un échec est BackupItem
        // `.failedPermanent`. Quand seul un `.failed` runtime existe sans
        // BackupItem correspondant, on retombe sur l'état cloud / localOnly.
        let asset = LocalAssetSnapshot(localIdentifier: "L5",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let cloud = photo(fileId: "F5", localId: "L5", date: date("2024-06-15"))

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [cloud],
            uploadStates: ["L5": .failed(reason: "boom")],
            calendar: cal
        )
        // Le cloud est synced → on affiche `.synced`, le runtime `.failed` est ignoré.
        XCTAssertEqual(sections[0].items[0].syncState, .synced)
    }

    func testQueuedBackupItem_mapsToPendingUpload() {
        // Cas nominal après reconciliation : l'asset entre en file mais aucun
        // upload n'a encore démarré. Le badge doit indiquer "en attente".
        let asset = LocalAssetSnapshot(localIdentifier: "L7",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let item = backupItem(localId: "L7", state: .queued)

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [],
            backupItems: [item.localIdentifier: item],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .pendingUpload)
    }

    func testFailedPermanentBackupItem_surfacedAsTappableReason() {
        // Scénario : sync terminée, `UploadQueue.clearCompleted()` a vidé le
        // runtime, mais BackupItem garde l'état et la cause. Le composer doit
        // exposer la raison pour que l'utilisateur puisse tap le badge orange.
        let asset = LocalAssetSnapshot(localIdentifier: "L8",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let item = backupItem(localId: "L8",
                              state: .failedPermanent,
                              reason: "Téléchargement iCloud impossible.")

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [],
            backupItems: [item.localIdentifier: item],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(
            sections[0].items[0].syncState,
            .uploadFailed(reason: "Téléchargement iCloud impossible.")
        )
    }

    func testRuntimeUploadingState_winsOverFailedPermanentBackupItem() {
        // Si une nouvelle tentative est en cours, l'UI doit montrer le spinner
        // (état runtime) et pas l'ancienne erreur persistée.
        let asset = LocalAssetSnapshot(localIdentifier: "L9",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let item = backupItem(localId: "L9",
                              state: .failedPermanent,
                              reason: "vieux message")

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [],
            backupItems: [item.localIdentifier: item],
            uploadStates: ["L9": .uploading(fraction: 0.1)],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .uploading(fraction: 0.1))
    }

    func testCloudSynced_winsOverFailedPermanentBackupItem() {
        // Edge case : un BackupItem `.failedPermanent` orphelin existe encore
        // (par ex. le clear a échoué), mais l'asset est désormais bien présent
        // côté cloud. La présence cloud gagne.
        let asset = LocalAssetSnapshot(localIdentifier: "L10",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let cloud = photo(fileId: "F10", localId: "L10", date: date("2024-06-15"))
        let item = backupItem(localId: "L10",
                              state: .failedPermanent,
                              reason: "vieux message")

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [cloud],
            backupItems: [item.localIdentifier: item],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .synced)
    }

    func testFailedTransientBackupItem_rendersAsLocalOnly_silentRetry() {
        // Phase 2a : un échec transient (réseau, 5xx, iCloud temporairement
        // indispo) ne doit PAS afficher de badge orange — l'item sera retenté
        // automatiquement après son `nextRetryAt`. Comportement Google Photos.
        let asset = LocalAssetSnapshot(localIdentifier: "L20",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let item = backupItem(localId: "L20",
                              state: .failedTransient,
                              reason: "Réseau indisponible")

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [],
            backupItems: [item.localIdentifier: item],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .localOnly)
    }

    func testSkippedBackupItem_rendersAsLocalOnly() {
        // L'utilisateur a explicitement skipé l'item. Phase 1a : visuellement
        // identique à `.localOnly` (nuage barré). Phase 2 introduira une icône
        // dédiée pour ne pas confondre "pas encore tenté" et "skippé".
        let asset = LocalAssetSnapshot(localIdentifier: "L11",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let item = backupItem(localId: "L11", state: .skipped, reason: "user choice")

        let sections = composer.compose(
            localAssets: [asset],
            cloudPhotos: [],
            backupItems: [item.localIdentifier: item],
            uploadStates: [:],
            calendar: cal
        )
        XCTAssertEqual(sections[0].items[0].syncState, .localOnly)
    }

    func testGrouping_sortsItemsByTakenAtDescending_andGroupsByMonth() {
        let assets = [
            LocalAssetSnapshot(localIdentifier: "A", takenAt: date("2024-06-15"), isVideo: false),
            LocalAssetSnapshot(localIdentifier: "B", takenAt: date("2024-05-30"), isVideo: false),
            LocalAssetSnapshot(localIdentifier: "C", takenAt: date("2024-06-01"), isVideo: false),
        ]

        let sections = composer.compose(localAssets: assets,
                                        cloudPhotos: [],
                                        uploadStates: [:],
                                        calendar: cal)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].month, 6, "Mois le plus récent en premier")
        XCTAssertEqual(sections[0].items.map(\.id), ["A", "C"])
        XCTAssertEqual(sections[1].month, 5)
        XCTAssertEqual(sections[1].items.map(\.id), ["B"])
    }

    func testNoDuplicate_whenLocalAndCloudShareLocalIdentifier() {
        // On NE veut PAS deux items pour la même photo (un local + un cloud).
        let asset = LocalAssetSnapshot(localIdentifier: "L6",
                                       takenAt: date("2024-06-15"),
                                       isVideo: false)
        let cloud = photo(fileId: "F6", localId: "L6", date: date("2024-06-15"))

        let sections = composer.compose(localAssets: [asset],
                                        cloudPhotos: [cloud],
                                        uploadStates: [:],
                                        calendar: cal)

        XCTAssertEqual(sections[0].items.count, 1)
    }

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: iso) ?? Date()
    }

    private func photo(fileId: String,
                       localId: String,
                       date: Date,
                       status: PhotoSyncStatus = .synced) -> PhotoSnapshot {
        PhotoSnapshot(
            id: fileId,
            driveId: 1,
            localIdentifier: localId,
            name: "\(fileId).jpg",
            takenAt: date,
            uploadedAt: date,
            mimeType: "image/jpeg",
            size: 0,
            isVideo: false,
            duration: 0,
            albumIds: [],
            syncStatus: status,
            isFavorite: false
        )
    }

    private func backupItem(localId: String,
                            state: BackupItemState,
                            reason: String = "") -> BackupItemSnapshot {
        let failed = state == .failedPermanent || state == .failedTransient
        return BackupItemSnapshot(
            localIdentifier: localId,
            state: state,
            clientToken: "tok-\(localId)",
            enqueuedAt: Date(),
            creationDate: date("2024-06-15"),
            isVideo: false,
            attemptCount: failed ? 1 : 0,
            lastAttemptAt: failed ? Date() : nil,
            nextRetryAt: state == .failedTransient ? Date().addingTimeInterval(60) : nil,
            lastErrorReason: reason
        )
    }
}
