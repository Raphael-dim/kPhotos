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

final class AuthErrorTests: XCTestCase {
    func testEveryCase_hasNonEmptyLocalizedDescription() throws {
        let cases: [AuthError] = [
            .notConfigured,
            .userCancelled,
            .stateMismatch,
            .missingAuthorizationCode,
            .tokenExchangeFailed(reason: "x"),
            .refreshFailed(reason: "y"),
            .noTokenStored,
            .keychainFailure(status: -25300),
            .invalidResponse
        ]
        for error in cases {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) doit exposer un message")
        }
    }

    func testTokenExchangeFailed_includesReason() throws {
        XCTAssertEqual(
            AuthError.tokenExchangeFailed(reason: "HTTP 400").errorDescription,
            "Échange de token échoué : HTTP 400"
        )
    }

    func testRefreshFailed_includesReason() throws {
        XCTAssertTrue(
            try (XCTUnwrap(
                AuthError.refreshFailed(reason: "token révoqué")
                    .errorDescription
            )).contains("token révoqué")
        )
    }

    func testKeychainFailure_includesStatusCode() throws {
        XCTAssertTrue(try (XCTUnwrap(AuthError.keychainFailure(status: -42).errorDescription)).contains("-42"))
    }
}
