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
    /// Télécharge un thumbnail JPEG (auth requis). Utiliser le cache côté UI.
    func thumbnailData(driveId: Int, fileId: String) async throws -> Data {
        let endpoint = Endpoint.thumbnail(driveId: driveId, fileId: fileId)
        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await requestThumbnail(endpoint: endpoint)
        }
    }

    private func requestThumbnail(endpoint: Endpoint) async throws -> Data {
        APILog.request(method: "GET", url: endpoint.url, body: nil)
        let response = await session
            .request(endpoint.url, method: .get)
            .validate()
            .serializingData()
            .response

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
