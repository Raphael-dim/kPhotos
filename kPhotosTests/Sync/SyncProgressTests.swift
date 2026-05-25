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

final class SyncProgressTests: XCTestCase {
    func testFraction_zeroTotal_isZero_noDivisionByZero() {
        XCTAssertEqual(SyncProgress(completed: 0, total: 0, lastUploadedFileName: nil).fraction, 0)
    }

    func testFraction_halfway() {
        XCTAssertEqual(
            SyncProgress(completed: 5, total: 10, lastUploadedFileName: nil).fraction,
            0.5, accuracy: 0.001
        )
    }

    func testFraction_complete() {
        XCTAssertEqual(
            SyncProgress(completed: 10, total: 10, lastUploadedFileName: nil).fraction,
            1.0, accuracy: 0.001
        )
    }
}

final class SyncPolicyErrorTests: XCTestCase {
    func testNetworkNotAllowed_offline_mentionsNoConnection() {
        let error = SyncPolicyError.networkNotAllowed(current: .offline, policy: .wifiOnly)
        XCTAssertEqual(error.errorDescription, "Aucune connexion réseau.")
    }

    func testNetworkNotAllowed_cellular_mentionsCellular() {
        let error = SyncPolicyError.networkNotAllowed(current: .cellular, policy: .wifiOnly)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("cellulaire"))
    }

    func testNetworkNotAllowed_wifi_mentionsWifi() {
        let error = SyncPolicyError.networkNotAllowed(current: .wifi, policy: [])
        XCTAssertTrue(error.errorDescription!.contains("Wi-Fi"))
    }

    func testNothingToSync_hasMessage() {
        XCTAssertEqual(SyncPolicyError.nothingToSync.errorDescription, "Aucune photo à synchroniser.")
    }
}

/// `PhotoSyncEngine.userFacingReason` traduit l'erreur d'upload en message FR.
final class PhotoSyncEngineErrorTests: XCTestCase {
    func testUserFacingReason_exportError_usesLocalizedDescription() {
        XCTAssertEqual(
            PhotoSyncEngine.userFacingReason(from: ExportError.noResource),
            ExportError.noResource.errorDescription
        )
    }

    func testUserFacingReason_apiError_usesLocalizedDescription() {
        XCTAssertEqual(
            PhotoSyncEngine.userFacingReason(from: PhotoAPIError.unauthorized),
            PhotoAPIError.unauthorized.errorDescription
        )
    }
}
