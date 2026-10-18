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
import kPhotosCore
import kPhotosResources

@MainActor
public final class SignInViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case validating
        case error(String)
        case success
    }

    /// Personal Access Tokens kDrive sont des chaînes longues base64url-like.
    /// On accepte large pour rester tolérant aux futurs formats, mais on rejette :
    /// - longueur < 20 ou > 256 (un PAT typique fait ~88 caractères)
    /// - caractères de contrôle / espaces internes (copier-coller foireux)
    /// - tout caractère hors du jeu `[A-Za-z0-9._~+/=-]`
    static let minTokenLength = 20
    static let maxTokenLength = 256
    static let allowedTokenCharacters = CharacterSet(
        charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+/=-"
    )

    @Published public private(set) var state: State = .idle
    @Published public var tokenInput: String = ""

    @InjectService private var auth: AuthService

    public init() {}

    public var canSubmit: Bool {
        Self.validate(tokenInput) == nil
    }

    public func submitToken() async {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.validate(trimmed) {
            state = .error(problem)
            return
        }

        state = .validating
        do {
            try await auth.acceptPAT(trimmed)
            tokenInput = ""
            state = .success
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Returns `nil` when the input looks like a syntactically valid PAT,
    /// otherwise a short human-readable reason.
    static func validate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.SignIn.PAT.Error.empty }
        guard trimmed.count >= minTokenLength else { return L10n.SignIn.PAT.Error.tooShort }
        guard trimmed.count <= maxTokenLength else { return L10n.SignIn.PAT.Error.tooLong }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return L10n.SignIn.PAT.Error.whitespace
        }
        guard trimmed.unicodeScalars.allSatisfy(allowedTokenCharacters.contains) else {
            return L10n.SignIn.PAT.Error.badCharacters
        }
        return nil
    }

    /// Réservé pour le jour où Infomaniak whitelistera le `client_id` (cf. AGENTS.md §20).
    public func signInWithOAuth() async {
        state = .validating
        let coordinator = WebAuthCoordinator()
        do {
            try await auth.signIn(using: coordinator)
            state = .success
        } catch AuthError.userCancelled {
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
