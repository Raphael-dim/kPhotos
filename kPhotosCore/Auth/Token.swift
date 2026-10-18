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

public struct AuthToken: Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?
    public let userId: Int?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        scope: String?,
        userId: Int?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.userId = userId
    }

    /// Marge de sécurité avant expiration pour déclencher un refresh préventif.
    public func isExpiring(within window: TimeInterval = 60) -> Bool {
        Date().addingTimeInterval(window) >= expiresAt
    }
}

/// Réponse brute du `/token` endpoint.
/// Infomaniak peut renvoyer `user_id` en Int OU en String, et `expires_in` peut être absent
/// (tokens illimités) — cf. github.com/Infomaniak/ios-login/Model/ApiToken.swift.
struct TokenResponseDTO: Decodable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?
    let scope: String?
    let userId: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case userId = "user_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        self.expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
        if let intId = try? container.decodeIfPresent(Int.self, forKey: .userId) {
            self.userId = intId
        } else if let stringId = try? container.decodeIfPresent(String.self, forKey: .userId) {
            self.userId = Int(stringId)
        } else {
            self.userId = nil
        }
    }

    func toAuthToken() -> AuthToken {
        // Sans `expires_in`, on considère le token comme non-expirant (10 ans).
        let lifetime = expiresIn.map(TimeInterval.init) ?? 60 * 60 * 24 * 365 * 10
        return AuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(lifetime),
            scope: scope,
            userId: userId
        )
    }
}
