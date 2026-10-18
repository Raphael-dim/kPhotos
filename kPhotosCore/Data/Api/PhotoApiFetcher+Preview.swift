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

public extension PhotoApiFetcher {
    /// Télécharge un preview JPEG (auth requis). Utilisé pour l'affichage plein écran.
    /// Les paramètres `width`/`height`/`quality` permettent de demander un preview HD ;
    /// sans paramètres on récupère le preview par défaut (basse résolution).
    func previewData(
        driveId: Int,
        fileId: String,
        width: Int? = nil,
        height: Int? = nil,
        quality: Int? = nil
    ) async throws -> Data {
        let endpoint = Endpoint.preview(
            driveId: driveId,
            fileId: fileId,
            width: width,
            height: height,
            quality: quality
        )
        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestPreview(endpoint: endpoint)
        }
    }

    func fileInfo(driveId: Int, fileId: String) async throws -> RemoteFileDetailDTO {
        let endpoint = Endpoint.fileInfo(driveId: driveId, fileId: fileId)
        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            try await waitForRequest(priority: 2)
            APILog.request(method: "GET", url: endpoint.url, body: nil)
            let response = await session
                .request(endpoint.url, method: .get)
                .validate()
                .serializingDecodable(InfomaniakResponse<RemoteFileDetailDTO>.self, decoder: decoder)
                .response
            try Task.checkCancellation()
            if let dto = response.value {
                APILog.response(url: endpoint.url, statusCode: response.response?.statusCode, body: response.data)
                return dto.data
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
    }

    private func requestPreview(endpoint: Endpoint) async throws -> Data {
        try await waitForRequest(priority: 2)
        APILog.request(method: "GET", url: endpoint.url, body: nil)
        let response = await session
            .request(endpoint.url, method: .get)
            .validate()
            .serializingData()
            .response
        try Task.checkCancellation()

        if let data = response.value {
            APILog.response(url: endpoint.url, statusCode: response.response?.statusCode, body: nil)
            return data
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
}
