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

@testable import kPhotosCore
import XCTest

/// Vérifie la règle métier centrale §6 d'AGENTS.md :
/// au moment de transformer un upload réussi en `Photo`, `takenAt` DOIT venir
/// de l'`ExportedAsset` (issu de `PHAsset.creationDate`), JAMAIS du
/// `created_at` renvoyé par le serveur. Ce mapping est le verrou anti-régression
/// du bug kDrive d'origine.
final class PhotoSyncEngineMappingTests: XCTestCase {
    func testMakePhotoFromExportedAsset_usesAssetTakenAt_notServerCreatedAt() {
        let assetDate = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01 UTC
        let serverDate = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC

        let exported = ExportedAsset(
            localIdentifier: "asset-1",
            fileURL: URL(fileURLWithPath: "/tmp/asset-1.jpg"),
            fileName: "20200101_000000_asset-1.jpg",
            takenAt: assetDate,
            mimeType: "image/jpeg",
            isVideo: false
        )

        let dto = RemoteFileDTO(
            id: "kdrive-1",
            name: "20200101_000000_asset-1.jpg",
            createdAt: Int(serverDate.timeIntervalSince1970),
            lastModifiedAt: Int(serverDate.timeIntervalSince1970),
            mimeType: "image/jpeg",
            size: 1234,
            hasThumbnail: true
        )

        let snapshot = PhotoSyncEngine.makeSnapshot(from: dto, exported: exported, driveId: 42)

        XCTAssertEqual(snapshot.takenAt, assetDate, "takenAt doit venir du PHAsset, pas du serveur")
        XCTAssertEqual(snapshot.uploadedAt, serverDate)
        XCTAssertEqual(snapshot.fileId, "kdrive-1")
        XCTAssertEqual(snapshot.driveId, 42)
        XCTAssertEqual(snapshot.localIdentifier, "asset-1")
        XCTAssertEqual(snapshot.syncStatus, .synced)
        XCTAssertFalse(snapshot.isVideo)
    }

    func testMakePhotoFromExportedAsset_preservesVideoFlag() {
        let exported = ExportedAsset(
            localIdentifier: "asset-2",
            fileURL: URL(fileURLWithPath: "/tmp/asset-2.mov"),
            fileName: "20240601_120000_asset-2.mov",
            takenAt: Date(),
            mimeType: "video/quicktime",
            isVideo: true
        )
        let dto = RemoteFileDTO(
            id: "kdrive-2",
            name: "20240601_120000_asset-2.mov",
            createdAt: 0,
            lastModifiedAt: 0,
            mimeType: "video/quicktime",
            size: 1,
            hasThumbnail: false
        )

        let snapshot = PhotoSyncEngine.makeSnapshot(from: dto, exported: exported, driveId: 1)

        XCTAssertTrue(snapshot.isVideo)
    }

    func testMakePhotoFromServer_fallbacksOnAddedAt_whenCreatedAtIsMissing() {
        // Régression : fichier uploadé depuis le web (screenshot sans EXIF) →
        // `created_at` à 0 côté API → on doit utiliser `added_at` pour ne pas
        // afficher 1970-01-01 dans la galerie.
        let addedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = RemoteFileDTO(
            id: "remote-web",
            name: "screenshot.png",
            createdAt: 0,
            addedAt: Int(addedDate.timeIntervalSince1970),
            lastModifiedAt: Int(addedDate.timeIntervalSince1970),
            mimeType: "image/png",
            size: 92200,
            hasThumbnail: true
        )

        let snapshot = PhotoSyncEngine.makeSnapshot(from: dto, driveId: 7)

        XCTAssertEqual(
            snapshot.takenAt,
            addedDate,
            "Sans EXIF côté serveur, on retombe sur added_at — jamais 1970."
        )
        XCTAssertEqual(snapshot.uploadedAt, addedDate)
    }

    // MARK: - Retry classifier (Phase 2a)

    func testClassify_noResource_isPermanent() {
        let decision = BackupRetryClassifier.classify(
            error: ExportError.noResource,
            attemptCount: 1
        )
        XCTAssertEqual(decision, .permanent)
    }

    func testClassify_missingCreationDate_isPermanent() {
        let decision = BackupRetryClassifier.classify(
            error: ExportError.missingCreationDate,
            attemptCount: 1
        )
        XCTAssertEqual(decision, .permanent)
    }

    func testClassify_writeFailed_isTransientWithLongBackoff() {
        // writeFailed = typiquement iCloud Photos qui n'arrive pas à descendre
        // l'original. base = 60s, attempt 1 → 60s.
        let decision = BackupRetryClassifier.classify(
            error: ExportError.writeFailed("icloud timeout"),
            attemptCount: 1
        )
        if case .transient(let retryAfter) = decision {
            XCTAssertEqual(retryAfter, 60, accuracy: 0.01)
        } else {
            XCTFail("Expected .transient, got \(decision)")
        }
    }

    func testClassify_network_isTransient() {
        let decision = BackupRetryClassifier.classify(
            error: PhotoAPIError.network(underlying: "no connection"),
            attemptCount: 1
        )
        if case .transient(let retryAfter) = decision {
            XCTAssertEqual(retryAfter, 30, accuracy: 0.01)
        } else {
            XCTFail("Expected .transient, got \(decision)")
        }
    }

    func testClassify_rateLimited_isTransient() {
        let decision = BackupRetryClassifier.classify(
            error: PhotoAPIError.rateLimited(retryAfter: nil),
            attemptCount: 1
        )
        guard case .transient = decision else {
            return XCTFail("Expected .transient, got \(decision)")
        }
    }

    func testClassify_server5xx_isTransient() {
        let decision = BackupRetryClassifier.classify(
            error: PhotoAPIError.server(statusCode: 503, message: nil),
            attemptCount: 1
        )
        guard case .transient = decision else {
            return XCTFail("Expected .transient, got \(decision)")
        }
    }

    func testClassify_unauthorized_isPermanent() {
        // Token révoqué → action user, pas de retry auto qui ne ferait que
        // cogner l'API.
        let decision = BackupRetryClassifier.classify(
            error: PhotoAPIError.unauthorized,
            attemptCount: 1
        )
        XCTAssertEqual(decision, .permanent)
    }

    func testClassify_server4xx_isPermanent() {
        let decision = BackupRetryClassifier.classify(
            error: PhotoAPIError.server(statusCode: 400, message: nil),
            attemptCount: 1
        )
        XCTAssertEqual(decision, .permanent)
    }

    func testClassify_transient_escalatesToPermanent_afterMaxAttempts() {
        // Au-delà du plafond `maxTransientAttempts`, toute erreur normalement
        // transient bascule en `.permanent` pour finir par alerter l'utilisateur.
        let decision = BackupRetryClassifier.classify(
            error: PhotoAPIError.network(underlying: "still down"),
            attemptCount: BackupRetryClassifier.maxTransientAttempts + 1
        )
        XCTAssertEqual(decision, .permanent)
    }

    func testBackoff_isExponential_andCappedAt24h() {
        // base = 30s, doublement par attempt :
        // a=1 → 30s, a=2 → 60, a=3 → 120, …, a=10 → 15360, a=20 → bornée.
        XCTAssertEqual(BackupRetryClassifier.backoff(forAttempt: 1, base: 30), 30, accuracy: 0.1)
        XCTAssertEqual(BackupRetryClassifier.backoff(forAttempt: 2, base: 30), 60, accuracy: 0.1)
        XCTAssertEqual(BackupRetryClassifier.backoff(forAttempt: 3, base: 30), 120, accuracy: 0.1)
        XCTAssertLessThanOrEqual(BackupRetryClassifier.backoff(forAttempt: 30, base: 30), 24 * 3600 + 0.1)
        XCTAssertEqual(BackupRetryClassifier.backoff(forAttempt: 100, base: 30), 24 * 3600, accuracy: 0.1)
    }

    func testMakePhotoFromServer_fallbackUsesServerCreatedAt() {
        // Quand on liste un dossier kDrive sans contexte d'export local, on n'a
        // que la date serveur. C'est le fallback acceptable — documenté §6/7.
        let serverCreated = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = RemoteFileDTO(
            id: "remote-only",
            name: "img.jpg",
            createdAt: Int(serverCreated.timeIntervalSince1970),
            lastModifiedAt: Int(serverCreated.timeIntervalSince1970),
            mimeType: "image/jpeg",
            size: 500,
            hasThumbnail: true
        )

        let snapshot = PhotoSyncEngine.makeSnapshot(from: dto, driveId: 7)

        XCTAssertEqual(snapshot.takenAt, serverCreated)
        XCTAssertEqual(snapshot.driveId, 7)
        XCTAssertTrue(
            snapshot.localIdentifier.isEmpty,
            "Pas de PHAsset connu — localIdentifier doit rester vide"
        )
    }
}
