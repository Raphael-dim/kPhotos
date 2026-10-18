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

import Foundation

public struct Endpoint {
    /// Host kDrive — tous les endpoints `/2/drive/...` et `/3/drive/...` y vivent.
    /// Cf. github.com/Infomaniak/ios-kDrive `apiDriveHost`. L'ancien `api.infomaniak.com`
    /// est l'API générale Infomaniak (mail, sms, etc.), pas kDrive.
    public static let baseURL: URL = {
        guard let url = URL(string: "https://api.kdrive.infomaniak.com") else {
            preconditionFailure("Invalid built-in kDrive endpoint")
        }
        return url
    }()

    /// Alias pour rétro-compat, identique à `baseURL`.
    public static let kDriveBaseURL = baseURL

    public let baseURL: URL
    public let path: String
    public let queryItems: [URLQueryItem]

    public init(
        baseURL: URL = Endpoint.baseURL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) {
        self.baseURL = baseURL
        self.path = path
        self.queryItems = queryItems
    }

    public var url: URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            fatalError("Invalid endpoint URL for path: \(path)")
        }
        return url
    }
}
