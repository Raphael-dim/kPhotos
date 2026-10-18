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

public struct AuthConfig: Equatable {
    public let clientId: String
    public let redirectURI: URL
    public let callbackScheme: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    public init(
        clientId: String,
        redirectURI: URL,
        callbackScheme: String,
        authorizationEndpoint: URL,
        tokenEndpoint: URL
    ) {
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.callbackScheme = callbackScheme
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    /// Default configuration for Infomaniak OAuth.
    ///
    /// `clientId` is a placeholder. Before re-enabling the OAuth sign-in flow
    /// (see AGENTS.md §20), register an OAuth application at
    /// https://manager.infomaniak.com/v3/profile/api-applications and replace
    /// the placeholder below with the issued client identifier.
    ///
    /// The OAuth flow is **inactive** in the current build (PAT is used
    /// instead), so a placeholder is acceptable here.
    public static let infomaniak = AuthConfig(
        clientId: "REPLACE_WITH_YOUR_INFOMANIAK_OAUTH_CLIENT_ID",
        redirectURI: URL(string: "app.kphotos://oauth/callback")!,
        callbackScheme: "app.kphotos",
        authorizationEndpoint: URL(string: "https://login.infomaniak.com/authorize")!,
        tokenEndpoint: URL(string: "https://login.infomaniak.com/token")!
    )

    public var isConfigured: Bool {
        !clientId.hasPrefix("REPLACE_") && !clientId.isEmpty
    }
}
