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

import AuthenticationServices
import Foundation
import kPhotosCore
import UIKit

/// Implémentation iOS de `WebAuthorizationProvider`. Vit dans `kPhotosFeatures`
/// pour garder `kPhotosCore` libre de UIKit / AuthenticationServices.
public final class WebAuthCoordinator: NSObject, WebAuthorizationProvider {
    private var session: ASWebAuthenticationSession?

    override public init() {}

    @MainActor
    public func presentAuthorization(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: AuthError.invalidResponse)
                return
            }
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.userCancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: AuthError.tokenExchangeFailed(
                        reason: error.localizedDescription
                    ))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.missingAuthorizationCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }
}

extension WebAuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.compactMap { $0 as? UIWindowScene }.first
        return windowScene?.keyWindow ?? ASPresentationAnchor()
    }
}
