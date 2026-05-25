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

import Alamofire
import Foundation

public extension PhotoApiFetcher {
    func listDrives() async throws -> [RemoteDriveDTO] {
        try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await self.requestDrives()
        }
    }

    private func requestDrives() async throws -> [RemoteDriveDTO] {
        APILog.request(method: "GET", url: Endpoint.listDrives.url, body: nil)
        let decoder = self.decoder
        let response = await session
            .request(Endpoint.listDrives.url, method: .get)
            .validate()
            .serializingDecodable(RemoteDriveListResponse.self, decoder: decoder)
            .response

        if let value = response.value {
            APILog.response(url: Endpoint.listDrives.url, statusCode: response.response?.statusCode, body: response.data)
            return value.data.drives
        }
        if let error = response.error {
            throw Self.mapAFError(error,
                                  statusCode: response.response?.statusCode,
                                  url: Endpoint.listDrives.url,
                                  body: response.data)
        }
        throw PhotoAPIError.invalidResponse
    }
}
