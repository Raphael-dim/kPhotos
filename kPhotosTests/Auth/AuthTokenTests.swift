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

final class AuthTokenTests: XCTestCase {
    func testIsExpiring_trueWhenExpiryFallsWithinWindow() {
        let token = makeToken(expiresAt: Date().addingTimeInterval(30))
        XCTAssertTrue(token.isExpiring(within: 60), "Expire dans 30s, fenêtre 60s → refresh préventif")
    }

    func testIsExpiring_falseWhenExpiryBeyondWindow() {
        let token = makeToken(expiresAt: Date().addingTimeInterval(600))
        XCTAssertFalse(token.isExpiring(within: 60))
    }

    func testIsExpiring_trueWhenAlreadyExpired() {
        let token = makeToken(expiresAt: Date().addingTimeInterval(-10))
        XCTAssertTrue(token.isExpiring())
    }

    private func makeToken(expiresAt: Date) -> AuthToken {
        AuthToken(accessToken: "a", refreshToken: "r", expiresAt: expiresAt, scope: nil, userId: nil)
    }
}

/// `TokenResponseDTO` doit absorber les variations de la réponse `/token`
/// d'Infomaniak : `user_id` en Int OU String, `expires_in` parfois absent.
final class TokenResponseDTOTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecode_userIdAsInt() throws {
        let json = #"{"access_token":"tok","expires_in":3600,"refresh_token":"ref","user_id":42}"#
        let dto = try decoder.decode(TokenResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.accessToken, "tok")
        XCTAssertEqual(dto.expiresIn, 3600)
        XCTAssertEqual(dto.refreshToken, "ref")
        XCTAssertEqual(dto.userId, 42)
    }

    func testDecode_userIdAsString_isParsedToInt() throws {
        let json = #"{"access_token":"tok","user_id":"99"}"#
        let dto = try decoder.decode(TokenResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.userId, 99)
    }

    func testDecode_missingUserId_isNil() throws {
        let dto = try decoder.decode(TokenResponseDTO.self, from: Data(#"{"access_token":"tok"}"#.utf8))
        XCTAssertNil(dto.userId)
        XCTAssertNil(dto.expiresIn)
    }

    func testDecode_throws_whenAccessTokenMissing() {
        XCTAssertThrowsError(try decoder.decode(TokenResponseDTO.self, from: Data(#"{"scope":"drive"}"#.utf8)))
    }

    func testToAuthToken_withExpiresIn_setsExpiryRoughlyThatFarOut() throws {
        let dto = try decoder.decode(
            TokenResponseDTO.self,
            from: Data(#"{"access_token":"tok","expires_in":3600}"#.utf8)
        )
        let token = dto.toAuthToken()
        XCTAssertEqual(token.expiresAt.timeIntervalSinceNow, 3600, accuracy: 5)
    }

    func testToAuthToken_withoutExpiresIn_isTreatedAsNonExpiring() throws {
        // Pas de `expires_in` → token "illimité" (lifetime 10 ans).
        let dto = try decoder.decode(
            TokenResponseDTO.self,
            from: Data(#"{"access_token":"tok"}"#.utf8)
        )
        let token = dto.toAuthToken()
        XCTAssertFalse(
            token.isExpiring(within: 60 * 60 * 24 * 365),
            "Sans expires_in, le token ne doit pas être considéré comme expirant"
        )
    }
}
