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

/// Décodage des DTO de l'API kDrive. Tolérance aux variations de typage
/// (`id` Int|String) et aux champs manquants — l'API n'est pas toujours stricte.
final class RemoteFileDTOTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecode_idAsInt_normalizedToString() throws {
        let json = #"{"id":12345,"name":"a.jpg"}"#
        let dto = try decoder.decode(RemoteFileDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, "12345")
    }

    func testDecode_idAsString() throws {
        let json = #"{"id":"abc-1","name":"a.jpg"}"#
        let dto = try decoder.decode(RemoteFileDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, "abc-1")
    }

    func testDecode_throws_whenIdMissing() {
        XCTAssertThrowsError(try decoder.decode(RemoteFileDTO.self, from: Data(#"{"name":"a"}"#.utf8)))
    }

    func testDecode_appliesDefaultsForMissingFields() throws {
        let dto = try decoder.decode(RemoteFileDTO.self, from: Data(#"{"id":"1","name":"a.jpg"}"#.utf8))
        XCTAssertEqual(dto.type, "file")
        XCTAssertEqual(dto.createdAt, 0)
        XCTAssertEqual(dto.addedAt, 0)
        XCTAssertEqual(dto.size, 0)
        XCTAssertFalse(dto.hasThumbnail)
        XCTAssertNil(dto.parentId)
    }

    func testDecode_parentIdAsInt_normalizedToString() throws {
        let json = #"{"id":"1","name":"a.jpg","parent_id":99}"#
        let dto = try decoder.decode(RemoteFileDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.parentId, "99")
    }

    func testDecode_mapsSnakeCaseKeys() throws {
        let json = #"""
        {"id":"1","name":"a.jpg","created_at":100,"added_at":200,
         "last_modified_at":300,"mime_type":"image/jpeg","has_thumbnail":true}
        """#
        let dto = try decoder.decode(RemoteFileDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.createdAt, 100)
        XCTAssertEqual(dto.addedAt, 200)
        XCTAssertEqual(dto.lastModifiedAt, 300)
        XCTAssertEqual(dto.mimeType, "image/jpeg")
        XCTAssertTrue(dto.hasThumbnail)
    }

    func testIsDirectory_reflectsType() {
        XCTAssertTrue(makeDTO(type: "dir").isDirectory)
        XCTAssertFalse(makeDTO(type: "file").isDirectory)
    }

    func testBestTakenAt_prefersCreatedAt() {
        XCTAssertEqual(makeDTO(createdAt: 100, addedAt: 200, lastModifiedAt: 300).bestTakenAt, 100)
    }

    func testBestTakenAt_prefersModificationOverUpload_whenCreatedAtZero() {
        XCTAssertEqual(makeDTO(createdAt: 0, addedAt: 200, lastModifiedAt: 300).bestTakenAt, 300)
    }

    func testBestTakenAt_fallsBackToUploadOnlyWhenOtherDatesAreMissing() {
        XCTAssertEqual(makeDTO(createdAt: 0, addedAt: 200, lastModifiedAt: 0).bestTakenAt, 200)
    }

    func testBestTakenAt_fallsBackToLastModified_whenCreatedAndAddedZero() {
        XCTAssertEqual(makeDTO(createdAt: 0, addedAt: 0, lastModifiedAt: 300).bestTakenAt, 300)
    }

    private func makeDTO(
        type: String = "file",
        createdAt: Int = 0,
        addedAt: Int = 0,
        lastModifiedAt: Int = 0
    ) -> RemoteFileDTO {
        RemoteFileDTO(
            id: "1",
            name: "a.jpg",
            type: type,
            createdAt: createdAt,
            addedAt: addedAt,
            lastModifiedAt: lastModifiedAt,
            mimeType: "image/jpeg",
            size: 0,
            hasThumbnail: false
        )
    }
}

final class RemoteFileListDTOTests: XCTestCase {
    func testDecode_pageWithCursorAndHasMore() throws {
        let json = #"""
        {"data":[{"id":"1","name":"a.jpg"}],"cursor":"NEXT","has_more":true}
        """#
        let dto = try JSONDecoder().decode(RemoteFileListDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.data.count, 1)
        XCTAssertEqual(dto.cursor, "NEXT")
        XCTAssertEqual(dto.hasMore, true)
    }

    func testDecode_lastPage_hasNilCursor() throws {
        let dto = try JSONDecoder().decode(
            RemoteFileListDTO.self,
            from: Data(#"{"data":[]}"#.utf8)
        )
        XCTAssertTrue(dto.data.isEmpty)
        XCTAssertNil(dto.cursor)
        XCTAssertNil(dto.hasMore)
    }
}

final class RemoteCategoryDTOTests: XCTestCase {
    func testDecode_fullCategory() throws {
        let json = ##"{"id":3,"name":"Vacances","color":"#FF5733","created_at":1000}"##
        let dto = try JSONDecoder().decode(RemoteCategoryDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, 3)
        XCTAssertEqual(dto.name, "Vacances")
        XCTAssertEqual(dto.color, "#FF5733")
        XCTAssertEqual(dto.createdAt, 1000)
    }

    func testDecode_minimalCategory_appliesDefaults() throws {
        // Réponse d'un PUT : pas de color ni created_at.
        let dto = try JSONDecoder().decode(
            RemoteCategoryDTO.self,
            from: Data(#"{"id":5,"name":"Famille"}"#.utf8)
        )
        XCTAssertNil(dto.color)
        XCTAssertEqual(dto.createdAt, 0)
    }

    func testDecode_insideInfomaniakEnvelope() throws {
        let json = #"{"result":"success","data":{"id":9,"name":"Album"}}"#
        let response = try JSONDecoder().decode(
            InfomaniakResponse<RemoteCategoryDTO>.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.data.id, 9)
        XCTAssertEqual(response.data.name, "Album")
    }
}

final class RemoteDirectoryDTOTests: XCTestCase {
    func testDecode_flexibleId() throws {
        let dto = try JSONDecoder().decode(
            RemoteDirectoryDTO.self,
            from: Data(#"{"id":777,"name":"kPhotos"}"#.utf8)
        )
        XCTAssertEqual(dto.id, "777")
        XCTAssertEqual(dto.name, "kPhotos")
    }
}

final class RemoteFileDetailDTOTests: XCTestCase {
    func testDecode_detailFields() throws {
        let json = #"""
        {"id":"42","name":"img.heic","path":"/Private/kPhotos/img.heic",
         "size":50000,"mime_type":"image/heic","created_at":111,"added_at":222,
         "last_modified_at":333,"hash":"abcdef","extension_type":"image"}
        """#
        let dto = try JSONDecoder().decode(RemoteFileDetailDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, "42")
        XCTAssertEqual(dto.size, 50000)
        XCTAssertEqual(dto.mimeType, "image/heic")
        XCTAssertEqual(dto.createdAt, 111)
        XCTAssertEqual(dto.addedAt, 222)
        XCTAssertEqual(dto.extensionType, "image")
    }
}

final class RemoteDriveDTOTests: XCTestCase {
    func testDecode_drive() throws {
        let json = #"{"id":5,"name":"Pro","size":1000,"used_size":250,"role":"admin","in_maintenance":false}"#
        let dto = try JSONDecoder().decode(RemoteDriveDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, 5)
        XCTAssertEqual(dto.name, "Pro")
        XCTAssertEqual(dto.usedSize, 250)
        XCTAssertEqual(dto.isInMaintenance, false)
    }

    func testDecode_driveListResponse_extractsNestedDrives() throws {
        let json = #"{"result":"success","data":{"drives":[{"id":1,"name":"A"},{"id":2,"name":"B"}]}}"#
        let response = try JSONDecoder().decode(RemoteDriveListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.drives.map(\.id), [1, 2])
    }
}
