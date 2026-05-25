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

/// Helpers purs de l'export PhotoKit : prédicat de fetch, nom de fichier
/// déterministe, mapping UTI → mime/extension. Pas d'accès PhotoKit réel.
final class PHAssetExporterTests: XCTestCase {
    func testPredicate_photosOnly_matchesImageMediaType() {
        XCTAssertEqual(PHAssetExporterImpl.predicate(for: .photosOnly)?.predicateFormat,
                       "mediaType == 1")
    }

    func testPredicate_videosOnly_matchesVideoMediaType() {
        XCTAssertEqual(PHAssetExporterImpl.predicate(for: .videosOnly)?.predicateFormat,
                       "mediaType == 2")
    }

    func testPredicate_both_orsImageAndVideo() {
        let format = PHAssetExporterImpl.predicate(for: .both)?.predicateFormat ?? ""
        XCTAssertTrue(format.contains("mediaType == 1"))
        XCTAssertTrue(format.contains("mediaType == 2"))
        XCTAssertTrue(format.contains("OR"))
    }

    func testPredicate_emptyFilter_matchesNothing() {
        // OptionSet vide → on ne synchronise rien.
        XCTAssertEqual(PHAssetExporterImpl.predicate(for: [])?.predicateFormat, "FALSEPREDICATE")
    }

    func testMakeFileName_standardUUID_isRecoverable() {
        // `20200101_000000_<id>.<ext>` — doit être réversible par
        // `PhotoManagerImpl.recoverLocalIdentifier`.
        let date = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01 00:00:00 UTC
        let name = PHAssetExporterImpl.makeFileName(
            creationDate: date,
            localIdentifier: "B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A/L0/001",
            uniformTypeIdentifier: "public.jpeg",
            originalFilename: "IMG_0001.JPG"
        )
        XCTAssertEqual(name, "20200101_000000_B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A-L0-001.jpg")
        XCTAssertEqual(PhotoManagerImpl.recoverLocalIdentifier(from: name),
                       "B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A/L0/001")
    }

    func testMakeFileName_emptyOriginalFilename_derivesExtensionFromUTI() {
        let name = PHAssetExporterImpl.makeFileName(
            creationDate: Date(timeIntervalSince1970: 1_577_836_800),
            localIdentifier: "ABC",
            uniformTypeIdentifier: "public.heic",
            originalFilename: ""
        )
        XCTAssertTrue(name.hasSuffix(".heic"))
    }

    func testMimeType_knownUTIs() {
        XCTAssertEqual(PHAssetExporterImpl.mimeType(from: "public.jpeg"), "image/jpeg")
        XCTAssertEqual(PHAssetExporterImpl.mimeType(from: "public.png"), "image/png")
        XCTAssertEqual(PHAssetExporterImpl.mimeType(from: "public.heic"), "image/heic")
        XCTAssertEqual(PHAssetExporterImpl.mimeType(from: "com.apple.quicktime-movie"), "video/quicktime")
        XCTAssertEqual(PHAssetExporterImpl.mimeType(from: "public.mpeg-4"), "video/mp4")
    }

    func testMimeType_unknownUTI_fallsBackToOctetStream() {
        XCTAssertEqual(PHAssetExporterImpl.mimeType(from: "public.unknown"), "application/octet-stream")
    }

    func testFileExtension_knownUTIs() {
        XCTAssertEqual(PHAssetExporterImpl.fileExtension(from: "public.jpeg"), "jpg")
        XCTAssertEqual(PHAssetExporterImpl.fileExtension(from: "public.png"), "png")
        XCTAssertEqual(PHAssetExporterImpl.fileExtension(from: "public.heic"), "heic")
        XCTAssertEqual(PHAssetExporterImpl.fileExtension(from: "com.apple.quicktime-movie"), "mov")
        XCTAssertEqual(PHAssetExporterImpl.fileExtension(from: "public.mpeg-4"), "mp4")
    }

    func testFileExtension_unknownUTI_fallsBackToDat() {
        XCTAssertEqual(PHAssetExporterImpl.fileExtension(from: "public.unknown"), "dat")
    }
}

final class ExportErrorTests: XCTestCase {
    func testEveryCase_hasNonEmptyDescription() {
        let cases: [ExportError] = [.noResource, .missingCreationDate, .writeFailed("io error")]
        for error in cases {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) doit exposer un message")
        }
    }

    func testWriteFailed_includesDetail() {
        XCTAssertTrue(ExportError.writeFailed("iCloud timeout").errorDescription!.contains("iCloud timeout"))
    }
}
