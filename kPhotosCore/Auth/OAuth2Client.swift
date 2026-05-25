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

import Foundation

/// OAuth 2.0 client avec PKCE — pure (pas d'UI, pas de WebAuthSession).
/// La récupération du `code` est déléguée à un `WebAuthorizationProvider`.
public final class OAuth2Client {
    private let config: AuthConfig
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    public init(config: AuthConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
    }

    public func buildAuthorizationURL(state: String, pkce: PKCEChallenge) -> URL {
        var components = URLComponents(url: config.authorizationEndpoint,
                                       resolvingAgainstBaseURL: false)!
        // Infomaniak n'utilise pas de paramètre `scope` — la portée est implicite au niveau du compte
        // (cf. github.com/Infomaniak/ios-login). `access_type=offline` est requis pour récupérer un refresh_token.
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else {
            preconditionFailure("Invalid authorization URL components")
        }
        return url
    }

    public func extractCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw AuthError.missingAuthorizationCode
        }
        let state = queryItems.first { $0.name == "state" }?.value
        guard state == expectedState else { throw AuthError.stateMismatch }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }
        return code
    }

    public func exchangeCode(_ code: String, pkceVerifier: String) async throws -> AuthToken {
        let body = formEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientId,
            "redirect_uri": config.redirectURI.absoluteString,
            "code_verifier": pkceVerifier
        ])
        do {
            let dto: TokenResponseDTO = try await postForm(url: config.tokenEndpoint, body: body)
            return dto.toAuthToken()
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.tokenExchangeFailed(reason: error.localizedDescription)
        }
    }

    public func refresh(_ refreshToken: String) async throws -> AuthToken {
        let body = formEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientId
        ])
        do {
            let dto: TokenResponseDTO = try await postForm(url: config.tokenEndpoint, body: body)
            return dto.toAuthToken()
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.refreshFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Private

    private func postForm<T: Decodable>(url: URL, body: Data) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? "no body"
            throw AuthError.tokenExchangeFailed(reason: "HTTP \(http.statusCode): \(snippet)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func formEncoded(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}
