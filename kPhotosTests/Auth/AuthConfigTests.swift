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

final class AuthConfigTests: XCTestCase {
    func testInfomaniakDefault_endpointsAndSchemeAreCorrect() throws {
        let config = AuthConfig.infomaniak
        XCTAssertEqual(config.callbackScheme, "app.kphotos")
        XCTAssertEqual(config.authorizationEndpoint.host, "login.infomaniak.com")
        XCTAssertEqual(config.tokenEndpoint.host, "login.infomaniak.com")
    }

    func testInfomaniakDefault_isNotConfiguredOutOfTheBox() throws {
        // The shipped client_id is a placeholder; the OAuth flow must be
        // explicitly configured by the user before it can be enabled.
        XCTAssertFalse(AuthConfig.infomaniak.isConfigured)
    }

    func testIsConfigured_falseWhenClientIdIsPlaceholder() throws {
        XCTAssertFalse(try makeConfig(clientId: "REPLACE_ME_WITH_REAL_ID").isConfigured)
    }

    func testIsConfigured_falseWhenClientIdIsEmpty() throws {
        XCTAssertFalse(try makeConfig(clientId: "").isConfigured)
    }

    func testIsConfigured_trueForRealClientId() throws {
        XCTAssertTrue(try makeConfig(clientId: "00000000-0000-4000-8000-000000000000").isConfigured)
    }

    private func makeConfig(clientId: String) throws -> AuthConfig {
        try AuthConfig(
            clientId: clientId,
            redirectURI: XCTUnwrap(URL(string: "app.kphotos://oauth/callback")),
            callbackScheme: "app.kphotos",
            authorizationEndpoint: XCTUnwrap(URL(string: "https://login.infomaniak.com/authorize")),
            tokenEndpoint: XCTUnwrap(URL(string: "https://login.infomaniak.com/token"))
        )
    }
}
