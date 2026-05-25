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

/// Vérifie la construction des URLs kDrive — chemins versionnés (`/2/` vs `/3/`)
/// et query params. Une URL erronée = 404 silencieux côté API.
final class EndpointTests: XCTestCase {
    func testURL_composesHostPathAndQuery() {
        let endpoint = Endpoint(path: "/2/drive/1/foo",
                                queryItems: [URLQueryItem(name: "a", value: "b")])
        let url = endpoint.url
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.kdrive.infomaniak.com")
        XCTAssertEqual(url.path, "/2/drive/1/foo")
        XCTAssertEqual(url.query, "a=b")
    }

    func testURL_omitsQuery_whenNoItems() {
        XCTAssertNil(Endpoint(path: "/2/drive/1/foo").url.query)
    }

    // MARK: - Albums / catégories

    func testCategories_listEndpoint() {
        XCTAssertEqual(Endpoint.categories(driveId: 7).url.path, "/2/drive/7/categories")
    }

    func testCategory_singleEndpoint() {
        XCTAssertEqual(Endpoint.category(driveId: 7, categoryId: 3).url.path,
                       "/2/drive/7/categories/3")
    }

    func testFileCategory_attachEndpoint() {
        XCTAssertEqual(Endpoint.fileCategory(driveId: 7, fileId: 100, categoryId: 3).url.path,
                       "/2/drive/7/files/100/categories/3")
    }

    func testFilesCategory_bulkEndpoint() {
        XCTAssertEqual(Endpoint.filesCategory(driveId: 7, categoryId: 3).url.path,
                       "/2/drive/7/files/categories/3")
    }

    func testCategoryFiles_usesV3AndLimit_withoutCursor() {
        let endpoint = Endpoint.categoryFiles(driveId: 7, categoryId: 3)
        XCTAssertEqual(endpoint.url.path, "/3/drive/7/categories/3/files")
        XCTAssertEqual(query(of: endpoint)["limit"], "100")
        XCTAssertNil(query(of: endpoint)["cursor"])
    }

    func testCategoryFiles_includesCursor_whenProvided() {
        let endpoint = Endpoint.categoryFiles(driveId: 7, categoryId: 3, cursor: "CUR", limit: 50)
        XCTAssertEqual(query(of: endpoint)["cursor"], "CUR")
        XCTAssertEqual(query(of: endpoint)["limit"], "50")
    }

    // MARK: - Photos / fichiers

    func testListFolder_usesV3() {
        let endpoint = Endpoint.listFolder(driveId: 7, folderId: "42")
        XCTAssertEqual(endpoint.url.path, "/3/drive/7/files/42/files")
        XCTAssertEqual(query(of: endpoint)["limit"], "100")
    }

    func testListFolder_includesCursor() {
        let endpoint = Endpoint.listFolder(driveId: 7, folderId: "42", cursor: "NEXT")
        XCTAssertEqual(query(of: endpoint)["cursor"], "NEXT")
    }

    func testUpload_carriesAllMetadataAsQueryParams() {
        let endpoint = Endpoint.upload(
            driveId: 7,
            directoryId: "10",
            fileName: "photo.jpg",
            totalSize: 2048,
            createdAt: 1_577_836_800,
            clientToken: "tok-abc"
        )
        XCTAssertEqual(endpoint.url.path, "/3/drive/7/upload")
        let q = query(of: endpoint)
        XCTAssertEqual(q["directory_id"], "10")
        XCTAssertEqual(q["file_name"], "photo.jpg")
        XCTAssertEqual(q["total_size"], "2048")
        XCTAssertEqual(q["created_at"], "1577836800")
        XCTAssertEqual(q["client_token"], "tok-abc")
        XCTAssertEqual(q["conflict"], "version", "Défaut documenté pour l'idempotence")
    }

    func testPreview_withoutParams_hasNoQuery() {
        XCTAssertNil(Endpoint.preview(driveId: 7, fileId: "42").url.query)
        XCTAssertEqual(Endpoint.preview(driveId: 7, fileId: "42").url.path,
                       "/2/drive/7/files/42/preview")
    }

    func testPreview_withDimensions_carriesQuery() {
        let endpoint = Endpoint.preview(driveId: 7, fileId: "42", width: 800, height: 600, quality: 90)
        let q = query(of: endpoint)
        XCTAssertEqual(q["width"], "800")
        XCTAssertEqual(q["height"], "600")
        XCTAssertEqual(q["quality"], "90")
    }

    func testThumbnailDownloadDeleteFileInfo_paths() {
        XCTAssertEqual(Endpoint.thumbnail(driveId: 7, fileId: "42").url.path,
                       "/2/drive/7/files/42/thumbnail")
        XCTAssertEqual(Endpoint.download(driveId: 7, fileId: "42").url.path,
                       "/2/drive/7/files/42/download")
        XCTAssertEqual(Endpoint.delete(driveId: 7, fileId: "42").url.path,
                       "/2/drive/7/files/42")
        XCTAssertEqual(Endpoint.fileInfo(driveId: 7, fileId: "42").url.path,
                       "/3/drive/7/files/42")
    }

    func testSearch_defaultsToImageType() {
        let endpoint = Endpoint.search(driveId: 7)
        XCTAssertEqual(endpoint.url.path, "/3/drive/7/files/search")
        XCTAssertEqual(query(of: endpoint)["type"], "image")
        XCTAssertEqual(query(of: endpoint)["limit"], "100")
    }

    func testCreateFolder_carriesParentAndName() {
        let endpoint = Endpoint.createFolder(driveId: 7, parentId: "1", folderName: "kPhotos")
        XCTAssertEqual(endpoint.url.path, "/3/drive/7/directories")
        XCTAssertEqual(query(of: endpoint)["parent_id"], "1")
        XCTAssertEqual(query(of: endpoint)["directory_name"], "kPhotos")
    }

    func testListDrives_targetsInitWithDrives() {
        XCTAssertEqual(Endpoint.listDrives.url.path, "/2/drive/init")
        XCTAssertEqual(query(of: Endpoint.listDrives)["with"], "drives")
    }

    // MARK: - Helpers

    private func query(of endpoint: Endpoint) -> [String: String] {
        let components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}
