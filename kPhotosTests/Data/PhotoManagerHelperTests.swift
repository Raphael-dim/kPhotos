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

/// Tests du parser `recoverLocalIdentifier` — clé de la Phase 2 du fix dédup :
/// récupérer le PHAsset id depuis le nom de fichier quand le record Realm a perdu
/// son `localIdentifier` (refresh distant qui avait écrasé le champ).
final class PhotoManagerHelperTests: XCTestCase {
    func testRecover_standardUUIDWithL0Suffix() {
        let result = PhotoManagerImpl.recoverLocalIdentifier(
            from: "20200101_000000_B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A-L0-001.jpg"
        )
        XCTAssertEqual(result, "B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A/L0/001")
    }

    func testRecover_uuidOnly() {
        // Cas rare mais possible — PHAsset sans suffixe.
        let result = PhotoManagerImpl.recoverLocalIdentifier(
            from: "20240601_120000_550E8400-E29B-41D4-A716-446655440000.heic"
        )
        XCTAssertEqual(result, "550E8400-E29B-41D4-A716-446655440000")
    }

    func testRecover_pngExtension() {
        let result = PhotoManagerImpl.recoverLocalIdentifier(
            from: "20260516_174657_ABC12345-1234-1234-1234-123456789ABC-L0-001.png"
        )
        XCTAssertEqual(result, "ABC12345-1234-1234-1234-123456789ABC/L0/001")
    }

    func testRecover_returnsNil_forWebUploadedFile() {
        // Fichier uploadé via le web kDrive — pas notre pattern → on n'invente rien.
        XCTAssertNil(PhotoManagerImpl.recoverLocalIdentifier(from: "screenshot.png"))
        XCTAssertNil(PhotoManagerImpl.recoverLocalIdentifier(from: "PP.JPG"))
        XCTAssertNil(PhotoManagerImpl.recoverLocalIdentifier(from: "vacances_2024.jpg"))
    }

    func testRecover_returnsNil_whenDatePrefixIsMalformed() {
        // 7 chiffres au lieu de 8 → reject.
        XCTAssertNil(PhotoManagerImpl.recoverLocalIdentifier(
            from: "2020101_000000_B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A-L0-001.jpg"
        ))
        // Lettres dans le préfixe daté → reject.
        XCTAssertNil(PhotoManagerImpl.recoverLocalIdentifier(
            from: "2020ABCD_000000_B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A-L0-001.jpg"
        ))
    }

    func testRecover_returnsNil_whenUUIDIsTruncated() {
        // Moins de 5 segments → pas de UUID valide.
        XCTAssertNil(PhotoManagerImpl.recoverLocalIdentifier(
            from: "20200101_000000_short-id.jpg"
        ))
    }
}

/// Tests purs sur le builder de predicate `PhotoLibraryObserverImpl.predicate(for:)`.
/// Pas d'interaction PhotoKit (le NSPredicate est statique, testable comme du texte).
final class PhotoLibraryObserverHelperTests: XCTestCase {
    func testPredicate_photosOnly_matchesImageMediaType() {
        let predicate = PhotoLibraryObserverImpl.predicate(for: .photosOnly)
        XCTAssertEqual(predicate.predicateFormat, "mediaType == 1")
    }

    func testPredicate_videosOnly_matchesVideoMediaType() {
        let predicate = PhotoLibraryObserverImpl.predicate(for: .videosOnly)
        XCTAssertEqual(predicate.predicateFormat, "mediaType == 2")
    }

    func testPredicate_both_orsImageAndVideo() {
        let predicate = PhotoLibraryObserverImpl.predicate(for: .both)
        // L'ordre des opérandes peut varier selon NSPredicate — on vérifie les
        // deux constantes présentes plutôt qu'une chaîne exacte fragile.
        XCTAssertTrue(predicate.predicateFormat.contains("mediaType == 1"))
        XCTAssertTrue(predicate.predicateFormat.contains("mediaType == 2"))
        XCTAssertTrue(predicate.predicateFormat.contains("OR"))
    }
}
