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

final class AuthConfigTests: XCTestCase {
    func testInfomaniakDefault_endpointsAndSchemeAreCorrect() {
        let config = AuthConfig.infomaniak
        XCTAssertEqual(config.callbackScheme, "app.kphotos")
        XCTAssertEqual(config.authorizationEndpoint.host, "login.infomaniak.com")
        XCTAssertEqual(config.tokenEndpoint.host, "login.infomaniak.com")
    }

    func testInfomaniakDefault_isNotConfiguredOutOfTheBox() {
        // The shipped client_id is a placeholder; the OAuth flow must be
        // explicitly configured by the user before it can be enabled.
        XCTAssertFalse(AuthConfig.infomaniak.isConfigured)
    }

    func testIsConfigured_falseWhenClientIdIsPlaceholder() {
        XCTAssertFalse(makeConfig(clientId: "REPLACE_ME_WITH_REAL_ID").isConfigured)
    }

    func testIsConfigured_falseWhenClientIdIsEmpty() {
        XCTAssertFalse(makeConfig(clientId: "").isConfigured)
    }

    func testIsConfigured_trueForRealClientId() {
        XCTAssertTrue(makeConfig(clientId: "00000000-0000-4000-8000-000000000000").isConfigured)
    }

    private func makeConfig(clientId: String) -> AuthConfig {
        AuthConfig(
            clientId: clientId,
            redirectURI: URL(string: "app.kphotos://oauth/callback")!,
            callbackScheme: "app.kphotos",
            authorizationEndpoint: URL(string: "https://login.infomaniak.com/authorize")!,
            tokenEndpoint: URL(string: "https://login.infomaniak.com/token")!
        )
    }
}
