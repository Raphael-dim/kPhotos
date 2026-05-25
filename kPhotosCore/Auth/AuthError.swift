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

public enum AuthError: Error, Equatable {
    case notConfigured
    case userCancelled
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(reason: String)
    case refreshFailed(reason: String)
    case noTokenStored
    case keychainFailure(status: Int32)
    case invalidResponse
}

extension AuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OAuth client_id manquant — édite kPhotosCore/Auth/AuthConfig.swift."
        case .userCancelled:
            return "Connexion annulée."
        case .stateMismatch:
            return "Réponse OAuth invalide (state mismatch). Réessaie."
        case .missingAuthorizationCode:
            return "Réponse OAuth sans code d'autorisation. Vérifie l'URL de redirection enregistrée dans le Manager Infomaniak."
        case .tokenExchangeFailed(let reason):
            return "Échange de token échoué : \(reason)"
        case .refreshFailed(let reason):
            return "Rafraîchissement du token échoué : \(reason)"
        case .noTokenStored:
            return "Aucun token stocké — connecte-toi."
        case .keychainFailure(let status):
            return "Erreur Keychain (code \(status))."
        case .invalidResponse:
            return "Réponse serveur invalide."
        }
    }
}
