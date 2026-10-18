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
import Security

public protocol TokenStorage: AnyObject {
    func load() throws -> AuthToken?
    func save(_ token: AuthToken) throws
    func clear() throws
}

/// Stockage Keychain — utilisé pour tous les tokens OAuth (cf. AGENTS.md §9/15).
public final class KeychainTokenStorage: TokenStorage {
    private let service: String
    private let account: String

    public init(service: String = "app.kphotos.auth", account: String = "token") {
        self.service = service
        self.account = account
    }

    public func load() throws -> AuthToken? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(AuthToken.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychainFailure(status: status)
        }
    }

    public func save(_ token: AuthToken) throws {
        let data = try JSONEncoder().encode(token)
        var query = baseQuery()
        query[kSecValueData as String] = data

        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributesToUpdate as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AuthError.keychainFailure(status: addStatus)
            }
        default:
            throw AuthError.keychainFailure(status: status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychainFailure(status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Utile pour les tests et les previews.
public final class InMemoryTokenStorage: TokenStorage {
    private var token: AuthToken?
    public init(initial: AuthToken? = nil) { self.token = initial }

    public func load() throws -> AuthToken? { token }
    public func save(_ token: AuthToken) throws { self.token = token }
    public func clear() throws { token = nil }
}
