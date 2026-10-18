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

/// Tests purs du client OAuth — construction d'URL et parsing du callback.
/// L'échange réseau (`exchangeCode`/`refresh`) n'est pas couvert ici.
final class OAuth2ClientTests: XCTestCase {
    private let client = OAuth2Client(config: .infomaniak)

    func testBuildAuthorizationURL_targetsAuthorizationEndpoint() {
        let url = client.buildAuthorizationURL(state: "s", pkce: PKCEChallenge(verifier: "v"))
        XCTAssertEqual(url.host, "login.infomaniak.com")
        XCTAssertEqual(url.path, "/authorize")
    }

    func testBuildAuthorizationURL_containsAllRequiredQueryItems() {
        let pkce = PKCEChallenge(verifier: "verifier-123")
        let url = client.buildAuthorizationURL(state: "state-xyz", pkce: pkce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], AuthConfig.infomaniak.clientId)
        XCTAssertEqual(query["redirect_uri"], AuthConfig.infomaniak.redirectURI.absoluteString)
        XCTAssertEqual(query["access_type"], "offline", "Requis pour obtenir un refresh_token")
        XCTAssertEqual(query["code_challenge"], pkce.challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "state-xyz")
    }

    func testExtractCode_returnsCode_onValidCallback() throws {
        let url = URL(string: "app.kphotos://oauth/callback?code=ABC123&state=expected")!
        XCTAssertEqual(try client.extractCode(from: url, expectedState: "expected"), "ABC123")
    }

    func testExtractCode_throwsStateMismatch_whenStateDiffers() {
        let url = URL(string: "app.kphotos://oauth/callback?code=ABC&state=tampered")!
        XCTAssertThrowsError(try client.extractCode(from: url, expectedState: "expected")) { error in
            XCTAssertEqual(error as? AuthError, .stateMismatch)
        }
    }

    func testExtractCode_throwsMissingCode_whenCodeAbsent() {
        let url = URL(string: "app.kphotos://oauth/callback?state=expected")!
        XCTAssertThrowsError(try client.extractCode(from: url, expectedState: "expected")) { error in
            XCTAssertEqual(error as? AuthError, .missingAuthorizationCode)
        }
    }

    func testExtractCode_throwsMissingCode_whenCodeIsEmpty() {
        let url = URL(string: "app.kphotos://oauth/callback?code=&state=expected")!
        XCTAssertThrowsError(try client.extractCode(from: url, expectedState: "expected")) { error in
            XCTAssertEqual(error as? AuthError, .missingAuthorizationCode)
        }
    }

    func testExtractCode_throwsMissingCode_whenCallbackHasNoQuery() {
        let url = URL(string: "app.kphotos://oauth/callback")!
        XCTAssertThrowsError(try client.extractCode(from: url, expectedState: "expected")) { error in
            XCTAssertEqual(error as? AuthError, .missingAuthorizationCode)
        }
    }
}
