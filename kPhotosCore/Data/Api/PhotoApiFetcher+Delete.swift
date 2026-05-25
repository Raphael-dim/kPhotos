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

public extension PhotoApiFetcher {
    func deleteFile(driveId: Int, fileId: String) async throws {
        let endpoint = Endpoint.delete(driveId: driveId, fileId: fileId)
        try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await self.requestDelete(endpoint: endpoint)
        }
    }

    private func requestDelete(endpoint: Endpoint) async throws {
        APILog.request(method: "DELETE", url: endpoint.url, body: nil)
        let response = await session
            .request(endpoint.url, method: .delete)
            .validate()
            .serializingData()
            .response

        if response.response != nil {
            APILog.response(url: endpoint.url, statusCode: response.response?.statusCode, body: response.data)
            return
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
