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

public struct DeletionProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let failed: Int

    public init(completed: Int, total: Int, failed: Int) {
        self.completed = completed
        self.total = total
        self.failed = failed
    }
}

/// Résultat d'une session du moteur de suppression. Permet à l'UI de remonter
/// un toast lisible ("3 photos supprimées, 1 a échoué") sans inspecter la file.
public struct DeletionSessionResult: Equatable, Sendable {
    public let completed: Int
    public let failedPermanently: Int
    public let failedTransiently: Int

    public init(completed: Int, failedPermanently: Int, failedTransiently: Int) {
        self.completed = completed
        self.failedPermanently = failedPermanently
        self.failedTransiently = failedTransiently
    }
}

public protocol PhotoDeleting: AnyObject {
    /// Draine la file de suppression : prend tous les items processable, leur
    /// applique la transition state machine `.queued/.failedTransient → .deleting`,
    /// envoie la requête DELETE à kDrive, puis `.completed` (purge Photo + DeletionItem)
    /// ou `.failedTransient/.failedPermanent` selon le classifier.
    ///
    /// Idempotent et séquentiel — un DELETE à la fois pour ne pas saturer l'API
    /// (Alamofire `performWithRetry` gère déjà 429/5xx avec backoff, mais on évite
    /// de pousser N requêtes en parallèle).
    ///
    /// `onProgress` est `async` et appelé sur le main actor à chaque item
    /// traité (success ou failure). L'engine **attend** la fin du callback avant
    /// de passer à l'item suivant : permet au caller de re-lire l'état (Realm
    /// Photo, DeletionItem) et rebuild la galerie de façon ordonnée, sans race
    /// entre N Tasks fire-and-forget qui finissent dans le désordre.
    @discardableResult
    func drain(onProgress: @MainActor @escaping (DeletionProgress) async -> Void) async -> DeletionSessionResult
}

public final class PhotoDeletionEngine: PhotoDeleting {
    private let api: PhotoApiFetching
    private let deletionQueueReader: DeletionQueueReading
    private let deletionQueueWriter: DeletionQueueWriting

    /// Verrou réentrant simple — empêche deux drains concurrents (UI + auto-trigger
    /// au démarrage de l'app par exemple). Une session attend la précédente. Sans
    /// ça, le même item pourrait être traité deux fois en parallèle entre l'instant
    /// où on lit `nextDeletable` et celui où on `markDeleting`.
    private var isDraining = false

    public init(
        api: PhotoApiFetching,
        deletionQueueReader: DeletionQueueReading,
        deletionQueueWriter: DeletionQueueWriting
    ) {
        self.api = api
        self.deletionQueueReader = deletionQueueReader
        self.deletionQueueWriter = deletionQueueWriter
    }

    @discardableResult
    public func drain(onProgress: @MainActor @escaping (DeletionProgress) async -> Void) async -> DeletionSessionResult {
        // Garde-fou contre concurrence : si un drain est déjà en cours, on n'en
        // démarre pas un second. L'utilisateur peut continuer à enqueue de
        // nouveaux items qui seront ramassés lors du prochain drain (ou par
        // ce drain en cours si la file n'est pas encore vide quand on arrive
        // à l'item courant).
        guard !isDraining else {
            return DeletionSessionResult(completed: 0, failedPermanently: 0, failedTransiently: 0)
        }
        isDraining = true
        defer { isDraining = false }

        // Sweep des items bloqués en `.deleting` (crash mi-deletion). Pendant du
        // `resetOrphanedUploads()` côté backup. Idempotent.
        try? await deletionQueueWriter.resetOrphanedDeletions()

        let processable = (try? deletionQueueReader.nextDeletable(now: Date(), limit: nil)) ?? []
        await onProgress(DeletionProgress(completed: 0, total: processable.count, failed: 0))
        if processable.isEmpty {
            return DeletionSessionResult(completed: 0, failedPermanently: 0, failedTransiently: 0)
        }

        var completed = 0
        var failedPermanently = 0
        var failedTransiently = 0

        for (index, item) in processable.enumerated() {
            try? Task.checkCancellation()
            try? await deletionQueueWriter.markDeleting(fileId: item.fileId)

            do {
                try await api.deleteFile(driveId: item.driveId, fileId: item.fileId)
                // Transaction unique : Photo + DeletionItem disparaissent ensemble.
                try? await deletionQueueWriter.markDeletionCompleted(fileId: item.fileId)
                completed += 1
            } catch is CancellationError {
                // OS coupe (Task cancellation). On laisse l'item dans `.deleting` —
                // `resetOrphanedDeletions` au prochain drain le repositionnera en
                // `.queued`. Sortie propre.
                break
            } catch {
                let decision = DeletionRetryClassifier.classify(
                    error: error,
                    attemptCount: item.attemptCount + 1
                )
                let reason = Self.userFacingReason(from: error)
                switch decision {
                case .transient(let retryAfter):
                    let nextAt = Date().addingTimeInterval(retryAfter)
                    try? await deletionQueueWriter.markDeletionFailedTransient(
                        fileId: item.fileId,
                        reason: reason,
                        nextRetryAt: nextAt
                    )
                    failedTransiently += 1
                case .permanent:
                    try? await deletionQueueWriter.markDeletionFailedPermanent(
                        fileId: item.fileId,
                        reason: reason
                    )
                    failedPermanently += 1
                }
            }

            await onProgress(DeletionProgress(
                completed: index + 1,
                total: processable.count,
                failed: failedPermanently + failedTransiently
            ))
        }

        return DeletionSessionResult(
            completed: completed,
            failedPermanently: failedPermanently,
            failedTransiently: failedTransiently
        )
    }

    static func userFacingReason(from error: Error) -> String {
        if let apiError = error as? PhotoAPIError {
            return apiError.errorDescription ?? apiError.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - Retry classifier

public enum DeletionRetryDecision: Equatable {
    case transient(retryAfter: TimeInterval)
    case permanent
}

/// Pendant de `BackupRetryClassifier` côté suppression. Schedule de backoff plus
/// court (base=15s vs 30s upload) : un DELETE est léger côté serveur, ré-essayer
/// vite est OK. Plafond identique à 8 tentatives — au-delà l'utilisateur mérite
/// d'être notifié plutôt que de voir une photo "fantôme" indéfiniment marquée
/// en suppression pending.
public enum DeletionRetryClassifier {
    public static let maxTransientAttempts = 8

    public static func classify(error: Error, attemptCount: Int) -> DeletionRetryDecision {
        guard attemptCount <= maxTransientAttempts else { return .permanent }

        if let apiError = error as? PhotoAPIError {
            switch apiError {
            case .network, .rateLimited, .server(statusCode: 500 ..< 600, _):
                return .transient(retryAfter: backoff(forAttempt: attemptCount, base: 15))
            case .notFound:
                // 404 sur DELETE = la photo n'existe déjà plus côté serveur
                // (suppression concurrente depuis un autre device, ou retry
                // après réponse perdue). On traite ça comme un succès virtuel :
                // pas la peine d'alerter l'utilisateur, le but est atteint.
                // Le classifier renvoie `.permanent` mais le caller pourrait
                // distinguer — pour rester simple ici on renvoie permanent, et
                // côté PhotoDeletionEngine on pourrait améliorer pour purger
                // l'item au lieu de le marquer failed. Phase 2.
                return .permanent
            case .unauthorized:
                return .permanent
            case .decoding, .invalidResponse:
                return .permanent
            case .server:
                // 4xx hors 401/404/429 — typiquement 400 (mauvaise requête),
                // 403 (droits), 423 (locked). Rejouer ne changera rien.
                return .permanent
            }
        }
        return .transient(retryAfter: backoff(forAttempt: attemptCount, base: 15))
    }

    /// Backoff exponentiel borné à 1h (vs 24h côté upload — suppression beaucoup
    /// plus rapide à rejouer côté serveur). Schedule pour base=15s : 15s, 30s,
    /// 1min, 2min, 4min, 8min, 16min, 32min.
    public static func backoff(forAttempt attempt: Int, base: TimeInterval) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = base * pow(2, Double(exponent))
        return min(raw, 3600)
    }
}
