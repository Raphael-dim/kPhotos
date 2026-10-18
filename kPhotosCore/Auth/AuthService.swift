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

/// Présente l'URL d'autorisation à l'utilisateur (généralement via
/// ASWebAuthenticationSession) et retourne l'URL de callback contenant le `code`.
/// L'implémentation iOS vit dans `kPhotosFeatures/Auth/WebAuthCoordinator.swift`
/// pour garder `kPhotosCore` libre de toute dépendance UI.
public protocol WebAuthorizationProvider: AnyObject {
    func presentAuthorization(url: URL, callbackScheme: String) async throws -> URL
}

public protocol AuthService: AnyObject {
    /// État courant de l'authentification.
    var isAuthenticated: Bool { get async }

    /// Token courant. Refresh automatique si proche de l'expiration (mode OAuth uniquement).
    func currentAccessToken() async throws -> String

    /// Lance le flow OAuth complet.
    /// Réservé au jour où le `client_id` kPhotos sera whitelisté par Infomaniak pour le scope `drive`.
    /// Le mode actif aujourd'hui est `acceptPAT(_:)`.
    func signIn(using webAuth: WebAuthorizationProvider) async throws

    /// Accepte un Personal Access Token créé manuellement par l'utilisateur dans Manager Infomaniak.
    /// Le token est considéré non-expirant ; aucun refresh n'est tenté.
    /// Cf. AGENTS.md §20 "Auth strategy".
    func acceptPAT(_ rawToken: String) async throws

    /// Efface le token local. Ne révoque pas côté serveur (à ajouter si endpoint dispo).
    func signOut() async throws
}

public final class AuthServiceImpl: AuthService {
    private let config: AuthConfig
    private let oauth: OAuth2Client
    private let storage: TokenStorage

    private let lock = NSLock()
    private var inFlightRefresh: Task<AuthToken, Error>?

    public init(config: AuthConfig, oauth: OAuth2Client, storage: TokenStorage) {
        self.config = config
        self.oauth = oauth
        self.storage = storage
    }

    public var isAuthenticated: Bool {
        get async {
            (try? storage.load()) != nil
        }
    }

    public func currentAccessToken() async throws -> String {
        guard let token = try storage.load() else { throw AuthError.noTokenStored }
        // PAT authentication does not depend on an OAuth client registration.
        if !token.isExpiring() { return token.accessToken }
        guard config.isConfigured else { throw AuthError.notConfigured }
        let refreshed = try await refreshIfNeeded(token)
        return refreshed.accessToken
    }

    public func signIn(using webAuth: WebAuthorizationProvider) async throws {
        guard config.isConfigured else { throw AuthError.notConfigured }
        let state = UUID().uuidString
        let pkce = PKCEChallenge()
        let url = try oauth.buildAuthorizationURL(state: state, pkce: pkce)

        let callbackURL = try await webAuth.presentAuthorization(
            url: url,
            callbackScheme: config.callbackScheme
        )
        let code = try oauth.extractCode(from: callbackURL, expectedState: state)
        let token = try await oauth.exchangeCode(code, pkceVerifier: pkce.verifier)
        try storage.save(token)
    }

    public func acceptPAT(_ rawToken: String) async throws {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AuthError.missingAuthorizationCode }
        // PAT créés sur Manager : durée "Illimité" → on simule 10 ans, pas de refresh_token.
        let token = AuthToken(
            accessToken: trimmed,
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 365 * 10),
            scope: nil,
            userId: nil
        )
        try storage.save(token)
    }

    public func signOut() async throws {
        try storage.clear()
    }

    // MARK: - Refresh coalescing

    private func refreshIfNeeded(_ token: AuthToken) async throws -> AuthToken {
        guard let refreshToken = token.refreshToken else {
            throw AuthError.refreshFailed(reason: "no refresh_token")
        }

        lock.lock()
        if let existing = inFlightRefresh {
            lock.unlock()
            return try await existing.value
        }
        let task = Task { [oauth, storage] in
            let refreshed = try await oauth.refresh(refreshToken)
            try storage.save(refreshed)
            return refreshed
        }
        inFlightRefresh = task
        lock.unlock()

        defer {
            lock.lock()
            inFlightRefresh = nil
            lock.unlock()
        }
        return try await task.value
    }
}
