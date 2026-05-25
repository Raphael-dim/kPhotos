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

public enum PhotoAPIError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case notFound
    case server(statusCode: Int, message: String?)
    case network(underlying: String)
    case decoding(underlying: String)
    case invalidResponse
}

extension PhotoAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Non autorisé (401/403) — token expiré ou révoqué."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limit Infomaniak (60 req/min). Réessai dans \(Int(retryAfter))s."
            }
            return "Rate limit Infomaniak (60 req/min)."
        case .notFound:
            return "Ressource introuvable (404)."
        case .server(let code, let message):
            return "Erreur serveur \(code)\(message.map { " — \($0)" } ?? "")."
        case .network(let underlying):
            return "Erreur réseau : \(underlying)"
        case .decoding(let underlying):
            return "Décodage JSON impossible : \(underlying)"
        case .invalidResponse:
            return "Réponse serveur invalide."
        }
    }
}

public enum UploadError: Error, Equatable {
    case missingCreationDate
    case fileNotReadable(path: String)
    case chunkFailed(index: Int, underlying: String)
    case quotaExceeded
    case cancelled
}

extension UploadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCreationDate:
            return "Asset sans date de création — impossible d'uploader (règle critique)."
        case .fileNotReadable(let path):
            return "Fichier illisible : \(path)"
        case .chunkFailed(let index, let underlying):
            return "Chunk \(index) échoué : \(underlying)"
        case .quotaExceeded:
            return "Quota kDrive dépassé."
        case .cancelled:
            return "Upload annulé."
        }
    }
}

public enum SyncError: Error, Equatable {
    case noPhotoLibraryAccess
    case checkpointCorrupted
    case backgroundBudgetExhausted
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noPhotoLibraryAccess:
            return "Accès à la photothèque refusé."
        case .checkpointCorrupted:
            return "Checkpoint de synchro corrompu."
        case .backgroundBudgetExhausted:
            return "Budget de tâches en arrière-plan épuisé."
        }
    }
}
