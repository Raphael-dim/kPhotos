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

// MARK: - Retry classifier

/// Décide si une erreur d'upload doit être retentée automatiquement (transient)
/// ou présentée à l'utilisateur (permanent). Calcule aussi le backoff exponentiel
/// par attempt count.
///
/// Le plafond `maxTransientAttempts` : au-delà, le classifier escalade en
/// `.permanent` même pour une erreur normalement transient — sinon une photo
/// qui rate indéfiniment (iCloud cassé en permanence, etc.) tournerait en boucle
/// dans la file sans jamais alerter l'utilisateur.
public enum BackupRetryDecision: Equatable {
    case transient(retryAfter: TimeInterval)
    case permanent
}

public enum BackupRetryClassifier {
    /// Plafond de retries transients avant escalade en `.failedPermanent`.
    /// Avec le schedule de backoff ci-dessous, 8 essais couvrent ~3 jours
    /// d'attente cumulée — au-delà l'utilisateur mérite d'être notifié plutôt
    /// que de laisser un item tourner silencieusement à l'infini.
    public static let maxTransientAttempts = 8

    public static func classify(error: Error, attemptCount: Int) -> BackupRetryDecision {
        // Escalade : au-delà du plafond, toute erreur transient devient permanent.
        guard attemptCount <= maxTransientAttempts else { return .permanent }

        if let safety = error as? BackupSafetyError {
            switch safety {
            case .incomplete, .integrity, .tooLarge: return .permanent
            case .busy: return .transient(retryAfter: 30)
            }
        }
        if let exportError = error as? ExportError {
            switch exportError {
            case .missingCreationDate, .noResource:
                // Problème structurel : pas de date EXIF, pas de ressource photo
                // exploitable (Live Photo cassée, RAW non supporté…). Retentent
                // ne changerait rien — c'est `.permanent` immédiat.
                return .permanent
            case .writeFailed:
                // `PHAssetResourceManager.writeData` a échoué — typiquement iCloud
                // Photos qui n'arrive pas à récupérer l'original (réseau, quota,
                // serveur Apple temporairement indispo). Long backoff car le
                // download iCloud peut prendre du temps avant de redevenir possible.
                return .transient(retryAfter: backoff(forAttempt: attemptCount, base: 60))
            }
        }
        if let apiError = error as? PhotoAPIError {
            switch apiError {
            case .network, .rateLimited, .server(statusCode: 500 ..< 600, _):
                // Réseau / 429 / 5xx — backoff agressif. `performWithRetry` côté
                // fetcher en aura déjà mangé 3 ; à ce stade c'est qu'on a un
                // vrai problème persistant à court terme.
                return .transient(retryAfter: backoff(forAttempt: attemptCount, base: 30))
            case .unauthorized:
                // 401/403 → token révoqué ou perdu. Action utilisateur requise
                // (re-login). Pas de retry auto qui ne ferait que cogner l'API.
                return .permanent
            case .notFound, .decoding, .invalidResponse:
                return .permanent
            case .server:
                // 4xx hors 401/404/429 (typiquement 400 = mauvaise requête, 409,
                // 413 = trop gros…) — rejouer ne changera pas le résultat.
                return .permanent
            }
        }
        // Erreur Swift native / inconnue — soyons conservateurs, on retente une fois
        // avant d'escalader. Si le bug est reproductible, l'escalade au plafond
        // finit par exposer la cause à l'utilisateur.
        return .transient(retryAfter: backoff(forAttempt: attemptCount, base: 30))
    }

    /// Backoff exponentiel borné à 24h.
    /// Schedule pour base=30s : 30s, 1min, 2min, 4min, 8min, 16min, 32min, 64min.
    /// Schedule pour base=60s (iCloud) : 1min, 2min, 4min, 8min, 16min, 32min, 64min, 128min.
    public static func backoff(forAttempt attempt: Int, base: TimeInterval) -> TimeInterval {
        let exponent = max(0, attempt - 1) // 1ère tentative ratée → 30s, pas 60s
        let raw = base * pow(2, Double(exponent))
        return min(raw, 24 * 3600)
    }
}

/// Finish the selected library, including a folder changed during a previous read.
/// Older scopes can remain cached, but must never become the visible result.
public struct CloudLibraryRefresh {
    private let drives: DriveManaging
    private let settings: SyncSettingsReading
    private let sync: PhotoSyncing
    private let photos: PhotoReading

    public init(drives: DriveManaging, settings: SyncSettingsReading, sync: PhotoSyncing, photos: PhotoReading) {
        self.drives = drives
        self.settings = settings
        self.sync = sync
        self.photos = photos
    }

    public func load() async throws -> [PhotoSnapshot] {
        while let drive = try drives.selectedDrive() {
            try Task.checkCancellation()
            let name = try settings.current().rootFolderName
            var root = drive.rootFolderId
            do {
                root = try await drives.existingRootFolder(folderName: name)
                try await sync.refreshFolder(driveId: drive.id, folderId: root)
                try Task.checkCancellation()
                guard try stillSelected(driveId: drive.id, root: root, name: name) else { continue }
                return try photos.allPhotos().filter {
                    $0.driveId == drive.id && $0.libraryRootId == root && $0.isAvailable
                }
            } catch {
                try Task.checkCancellation()
                // A failure for an obsolete folder must not prevent the newly selected one loading.
                guard try stillSelected(driveId: drive.id, root: root, name: name) else { continue }
                throw error
            }
        }
        return []
    }

    private func stillSelected(driveId: Int, root: String, name: String) throws -> Bool {
        guard let current = try drives.selectedDrive() else { return false }
        let currentName = try settings.current().rootFolderName
        return current.id == driveId && current.rootFolderId == root && currentName == name
    }
}
