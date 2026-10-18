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

/// PKCE (RFC 7636) — vérifie le calcul du `code_challenge` et l'encodage base64url.
/// Un challenge erroné fait rejeter l'échange de token par Infomaniak.
final class PKCETests: XCTestCase {
    func testChallenge_matchesRFC7636TestVector() {
        // Vecteur officiel RFC 7636, Appendix B : challenge = base64url(SHA256(verifier)).
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            PKCEChallenge.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testInit_withExplicitVerifier_derivesChallengeAndUsesS256() {
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(pkce.method, "S256")
    }

    func testInit_withoutVerifier_generatesConsistentChallenge() {
        let pkce = PKCEChallenge()
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertEqual(pkce.challenge, PKCEChallenge.challenge(for: pkce.verifier))
    }

    func testMakeVerifier_isRandom_andBase64URLSafe() {
        let first = PKCEChallenge.makeVerifier()
        let second = PKCEChallenge.makeVerifier()
        XCTAssertNotEqual(first, second, "Chaque verifier doit être tiré aléatoirement")
        for verifier in [first, second] {
            // base64url sans padding — RFC 4648 §5.
            XCTAssertFalse(verifier.contains("+"))
            XCTAssertFalse(verifier.contains("/"))
            XCTAssertFalse(verifier.contains("="))
        }
    }

    func testBase64URLEncodedString_stripsPadding() {
        // 2 octets → 3 caractères base64 + 1 padding `=` côté standard.
        XCTAssertEqual(Data([0x3E, 0xFF]).base64EncodedString(), "Pv8=")
        XCTAssertEqual(Data([0x3E, 0xFF]).base64URLEncodedString(), "Pv8")
    }

    func testBase64URLEncodedString_replacesPlusAndSlash() {
        // Octets choisis pour produire `+` et `/` en base64 standard.
        XCTAssertEqual(Data([0xFB, 0xFF, 0xBF]).base64EncodedString(), "+/+/")
        XCTAssertEqual(Data([0xFB, 0xFF, 0xBF]).base64URLEncodedString(), "-_-_")
    }
}
