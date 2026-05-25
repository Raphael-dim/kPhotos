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
 */

import Alamofire
import Foundation

/// Page de listing : items + cursor pour la page suivante (nil = fin).
public struct FilePage: Equatable {
    public let items: [RemoteFileDTO]
    public let nextCursor: String?

    public init(items: [RemoteFileDTO], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public extension PhotoApiFetcher {
    /// Liste le contenu d'un dossier kDrive en pagination cursor v3.
    /// Cf. spec OpenAPI : `GET /3/drive/{drive_id}/files/{file_id}/files?limit&cursor`.
    /// Itère le cursor jusqu'à `nextCursor == nil` côté caller pour récupérer tout.
    func listFolder(driveId: Int, folderId: String, cursor: String? = nil, limit: Int = 100) async throws -> FilePage {
        let endpoint = Endpoint.listFolder(driveId: driveId, folderId: folderId, cursor: cursor, limit: limit)
        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await self.requestList(endpoint: endpoint)
        }
    }

    /// Crée un sous-dossier dans `parentId` du drive.
    /// Cf. ios-kDrive `Endpoint+Files.swift` : `POST /3/drive/{driveId}/files/{parentId}/directory`.
    /// `only_for_me: true` est requis sinon HTTP 400. kPhotos = sauvegarde perso → toujours `true`.
    func createDirectory(driveId: Int, name: String, parentId: String) async throws -> RemoteDirectoryDTO {
        let endpoint = Endpoint(path: "/3/drive/\(driveId)/files/\(parentId)/directory")
        let payload: [String: Any] = [
            "name": name,
            "only_for_me": true
        ]

        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await self.requestJSON(endpoint: endpoint, method: .post, parameters: payload)
        }
    }

    internal func requestList(endpoint: Endpoint) async throws -> FilePage {
        APILog.request(method: "GET", url: endpoint.url, body: nil)
        let decoder = self.decoder
        let response = await session
            .request(endpoint.url, method: .get)
            .validate()
            .serializingDecodable(RemoteFileListDTO.self, decoder: decoder)
            .response

        if let dto = response.value {
            APILog.response(url: endpoint.url, statusCode: response.response?.statusCode, body: response.data)
            let next: String? = (dto.hasMore == true) ? dto.cursor : nil
            return FilePage(items: dto.data, nextCursor: next)
        }

        if let error = response.error {
            throw Self.mapAFError(error,
                                  statusCode: response.response?.statusCode,
                                  url: endpoint.url,
                                  body: response.data)
        }

        throw PhotoAPIError.invalidResponse
    }
}
