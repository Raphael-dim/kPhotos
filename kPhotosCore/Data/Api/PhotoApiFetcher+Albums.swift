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

import Alamofire
import Foundation

/// Implémentation "album" — sur les **catégories kDrive** natives. Cf. `Endpoint+Albums.swift`.
public extension PhotoApiFetcher {
    // MARK: - Catégories (= albums)

    func listCategories(driveId: Int) async throws -> [RemoteCategoryDTO] {
        let endpoint = Endpoint.categories(driveId: driveId)
        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestJSON(endpoint: endpoint, method: .get)
        }
    }

    func createCategory(driveId: Int, name: String, color: String? = nil) async throws -> RemoteCategoryDTO {
        let endpoint = Endpoint.categories(driveId: driveId)
        var payload: [String: Any] = ["name": name]
        if let color { payload["color"] = color }

        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestJSON(endpoint: endpoint, method: .post, parameters: payload)
        }
    }

    func updateCategory(driveId: Int, categoryId: Int, name: String?, color: String?) async throws -> RemoteCategoryDTO {
        let endpoint = Endpoint.category(driveId: driveId, categoryId: categoryId)
        var payload: [String: Any] = [:]
        if let name { payload["name"] = name }
        if let color { payload["color"] = color }

        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestJSON(endpoint: endpoint, method: .put, parameters: payload)
        }
    }

    func deleteCategory(driveId: Int, categoryId: Int) async throws {
        let endpoint = Endpoint.category(driveId: driveId, categoryId: categoryId)
        _ = try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestEmpty(endpoint: endpoint, method: .delete)
        }
    }

    // MARK: - Attache catégorie ↔ fichier(s)

    /// Bulk natif kDrive : attache `categoryId` à N fichiers en 1 appel. À privilégier
    /// dès qu'on a >1 fichier (sélection timeline) — N round-trips réseau économisés.
    func addCategoryToFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws {
        let endpoint = Endpoint.filesCategory(driveId: driveId, categoryId: categoryId)
        let payload: [String: Any] = ["file_ids": fileIds]

        _ = try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestEmpty(endpoint: endpoint, method: .post, parameters: payload)
        }
    }

    /// Bulk natif kDrive : détache `categoryId` de N fichiers en 1 appel.
    func removeCategoryFromFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws {
        let endpoint = Endpoint.filesCategory(driveId: driveId, categoryId: categoryId)
        let payload: [String: Any] = ["file_ids": fileIds]

        _ = try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestEmpty(endpoint: endpoint, method: .delete, parameters: payload)
        }
    }

    // MARK: - Listing des fichiers d'une catégorie (paginé v3)

    func listCategoryFiles(
        driveId: Int,
        categoryId: Int,
        cursor: String? = nil,
        limit: Int = 100
    ) async throws -> FilePage {
        let endpoint = Endpoint.categoryFiles(driveId: driveId, categoryId: categoryId, cursor: cursor, limit: limit)
        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestList(endpoint: endpoint)
        }
    }

    // MARK: - Internals

    internal func requestJSON<T: Decodable>(
        endpoint: Endpoint,
        method: HTTPMethod,
        parameters: [String: Any]? = nil
    ) async throws -> T {
        try await waitForRequest()
        APILog.request(method: method.rawValue, url: endpoint.url, body: parameters)
        let decoder = decoder
        let request: DataRequest
        if let parameters {
            request = session.request(
                endpoint.url,
                method: method,
                parameters: parameters,
                encoding: JSONEncoding.default
            )
        } else {
            request = session.request(endpoint.url, method: method)
        }
        let response = await request
            .validate()
            .serializingDecodable(InfomaniakResponse<T>.self, decoder: decoder)
            .response
        try Task.checkCancellation()

        if let value = response.value {
            APILog.response(url: endpoint.url, statusCode: response.response?.statusCode, body: response.data)
            return value.data
        }
        if let error = response.error {
            throw Self.mapAFError(
                error,
                statusCode: response.response?.statusCode,
                url: endpoint.url,
                body: response.data
            )
        }
        throw PhotoAPIError.invalidResponse
    }

    internal func requestEmpty(
        endpoint: Endpoint,
        method: HTTPMethod,
        parameters: [String: Any]? = nil
    ) async throws -> Bool {
        try await waitForRequest()
        APILog.request(method: method.rawValue, url: endpoint.url, body: parameters)
        let request: DataRequest
        if let parameters {
            request = session.request(
                endpoint.url,
                method: method,
                parameters: parameters,
                encoding: JSONEncoding.default
            )
        } else {
            request = session.request(endpoint.url, method: method)
        }
        let response = await request
            .validate()
            .serializingData()
            .response
        try Task.checkCancellation()

        if response.error == nil {
            APILog.response(url: endpoint.url, statusCode: response.response?.statusCode, body: response.data)
            return true
        }
        if let error = response.error {
            throw Self.mapAFError(
                error,
                statusCode: response.response?.statusCode,
                url: endpoint.url,
                body: response.data
            )
        }
        return false
    }
}
