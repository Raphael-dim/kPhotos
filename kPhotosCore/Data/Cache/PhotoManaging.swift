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

import Combine
import Foundation
import RealmSwift

// Interface Segregation : on expose lecture et écriture séparément.
// Toutes les méthodes renvoient des `PhotoSnapshot` (value type) — JAMAIS un Photo Realm
// managé qui crasherait au franchissement d'une frontière async (cf. AGENTS.md §21).

public protocol PhotoReading: AnyObject {
    func photo(byFileId fileId: String) throws -> PhotoSnapshot?
    func photo(byLocalIdentifier localIdentifier: String) throws -> PhotoSnapshot?
    func allPhotos() throws -> [PhotoSnapshot]
    var changesPublisher: AnyPublisher<Void, Never> { get }
}

public extension PhotoReading {
    var changesPublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
}

public protocol PhotoWriting: AnyObject {
    /// Upsert avec écrasement total — utilisé après un upload local où on a la vérité
    /// complète (PHAsset + DTO). Tous les champs du snapshot remplacent l'existant.
    func upsert(_ photo: PhotoSnapshot) async throws
    func upsert(_ photos: [PhotoSnapshot]) async throws
    /// Upsert depuis un listing distant kDrive : préserve les champs client-side
    /// (`localIdentifier`, `isFavorite`, `albumIds`) absents du listing serveur.
    /// Sans ça, un `refreshFolder` casserait la dédup local↔cloud du `GalleryComposer`
    /// (qui matche par `localIdentifier`) → photos dupliquées dans la galerie.
    func upsertFromListing(_ photos: [PhotoSnapshot]) async throws
    func commitListing(
        _ photos: [PhotoSnapshot],
        driveId: Int,
        folderId: String,
        fileIds: Set<String>,
        revisions: [String: String]
    ) async throws
    func updateEmbeddedMetadata(driveId: Int, fileId: String, revision: String, metadata: EmbeddedMediaMetadata) async throws
    func applyMediaIndex(_ index: MediaLibraryIndex) async throws
    func updateSyncStatus(fileId: String, status: PhotoSyncStatus) async throws
    func setFavorite(fileId: String, isFavorite: Bool) async throws
    func delete(fileId: String) async throws
}

public extension PhotoWriting {
    func applyMediaIndex(_ index: MediaLibraryIndex) async throws { throw PhotoAPIError.invalidResponse }
    func updateEmbeddedMetadata(driveId: Int, fileId: String, revision: String, metadata: EmbeddedMediaMetadata) async throws {
        throw PhotoAPIError.invalidResponse
    }
}

/// File de sauvegarde persistante. Indexée par `localIdentifier` du PHAsset.
/// Cf. `BackupItem` pour la sémantique du state machine.
public protocol BackupQueueReading: AnyObject {
    var backupChangesPublisher: AnyPublisher<Void, Never> { get }
    /// Tous les items, indépendamment de leur état. Tri non garanti.
    func allItems() throws -> [BackupItemSnapshot]

    /// Items prêts à être traités au prochain coup de moteur :
    ///   - `.queued` (jamais tentés)
    ///   - `.failedTransient` dont `nextRetryAt <= now()` (backoff écoulé)
    /// Triés `creationDate desc` (newest first, comportement Google Photos :
    /// on backuppe d'abord ce que l'utilisateur vient de prendre).
    /// `limit = nil` pour drainer toute la file.
    func nextProcessable(now: Date, limit: Int?) throws -> [BackupItemSnapshot]

    /// Récupère un item par sa clé primaire. Retourne nil si l'asset n'est pas
    /// (ou plus) dans la file.
    func item(localIdentifier: String) throws -> BackupItemSnapshot?

    /// `localIdentifier` des items en `.completed` — utilisé par le reconciler
    /// pour ne pas re-enqueue ce qui est déjà uploadé.
    func completedLocalIdentifiers() throws -> Set<String>
}

public extension BackupQueueReading {
    var backupChangesPublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
}

public protocol BackupQueueWriting: AnyObject {
    /// Réconcilie toute la photothèque en une transaction, sans rouvrir Realm
    /// pour chaque photo. Les items déjà connus gardent leur clientToken.
    func reconcile(localAssets: [LocalAssetSnapshot], syncedIdentifiers: Set<String>) async throws

    /// Ajoute un asset s'il n'est pas déjà en file. No-op si un item existe déjà
    /// pour ce `localIdentifier` (quel que soit son état) — la dédup est gérée
    /// par la clé primaire Realm + ce garde-fou.
    /// Génère un `clientToken` UUID stable persisté pour la vie de l'item.
    func enqueueIfAbsent(
        localIdentifier: String,
        creationDate: Date,
        isVideo: Bool
    ) async throws

    /// Transitions de state machine. Garantit l'atomicité d'une bascule
    /// state + métadonnées associées (lastAttemptAt, lastErrorReason, attemptCount).
    func markUploading(localIdentifier: String) async throws
    func markCompleted(localIdentifier: String) async throws
    /// Marque l'item comme échec transient avec date de prochaine tentative.
    /// Le worker reprendra cet item dès que `now() >= nextRetryAt` au prochain
    /// coup de moteur (sync manuelle ou BG). Ne réinitialise PAS `attemptCount` —
    /// permet au classifier d'allonger le backoff sur les retries successifs.
    func markFailedTransient(
        localIdentifier: String,
        reason: String,
        nextRetryAt: Date
    ) async throws
    func markFailedPermanent(localIdentifier: String, reason: String) async throws
    func markSkipped(localIdentifier: String, reason: String) async throws

    /// Re-enqueue forcée d'un item `.failedPermanent` ou `.skipped` — utilisé par
    /// l'action "Réessayer" dans l'UI. Conserve `clientToken` pour rester
    /// idempotent côté serveur.
    func requeue(localIdentifier: String) async throws

    /// Re-enqueue en masse de tous les items `.failedPermanent` — action globale
    /// "Tout réessayer" du toolbar. Atomique côté Realm (une seule transaction).
    /// Retourne le nombre d'items requeued (utile pour feedback toast).
    @discardableResult
    func requeueAllPermanentlyFailed() async throws -> Int

    /// Réinitialise tous les items bloqués en `.uploading` vers `.queued`.
    /// Cas d'usage : crash app, BGTask coupée mi-upload, kill par l'OS. Sans
    /// ce sweep, un item resterait orphelin dans `.uploading` et ne serait
    /// jamais repris par `nextProcessable`. Idempotent. Retourne le nombre
    /// d'items resets pour observabilité.
    @discardableResult
    func resetOrphanedUploads() async throws -> Int
}

public typealias BackupQueueing = BackupQueueReading & BackupQueueWriting

/// File de suppression persistante. Indexée par `fileId` (clé primaire kDrive).
/// Symétrique à `BackupQueueReading` côté lifecycle, voir `DeletionItem` pour
/// la sémantique du state machine.
public protocol DeletionQueueReading: AnyObject {
    /// Tous les items, indépendamment de leur état. Tri non garanti.
    func allDeletions() throws -> [DeletionItemSnapshot]

    /// Items prêts à être supprimés au prochain coup de moteur :
    ///   - `.queued` (jamais tentés)
    ///   - `.failedTransient` dont `nextRetryAt <= now()` (backoff écoulé)
    /// Triés `enqueuedAt asc` (FIFO — on traite d'abord ce qui attend depuis
    /// le plus longtemps).
    func nextDeletable(now: Date, limit: Int?) throws -> [DeletionItemSnapshot]

    /// Récupère un item par son `fileId`. Retourne nil si pas en file.
    func deletionItem(fileId: String) throws -> DeletionItemSnapshot?

    /// Set des `fileId` actuellement en file (quel que soit l'état) — utilisé
    /// par le composer pour piloter le badge "deletion in progress" en O(1).
    func pendingDeletionFileIds() throws -> Set<String>
}

public protocol DeletionQueueWriting: AnyObject {
    /// A Live Photo's still and motion must enter the queue in one Realm transaction.
    func enqueueDeletions(_ requests: [DeletionRequest]) async throws
    /// Enqueue une suppression. No-op si un item existe déjà pour ce `fileId`
    /// (sauf s'il était en `.failedPermanent` — auquel cas on le re-queue,
    /// l'utilisateur a explicitement re-déclenché la suppression).
    func enqueueDeletion(
        fileId: String,
        driveId: Int,
        localIdentifier: String
    ) async throws

    func markDeleting(fileId: String) async throws
    /// Marque comme `.completed` ET supprime le `Photo` Realm correspondant.
    /// Transaction unique → l'UI ne peut jamais observer un état intermédiaire
    /// "photo encore présente, suppression complète". Purge aussi l'entry
    /// DeletionItem (l'historique des completed n'a aucune utilité).
    func markDeletionCompleted(fileId: String) async throws
    func markDeletionFailedTransient(
        fileId: String,
        reason: String,
        nextRetryAt: Date
    ) async throws
    func markDeletionFailedPermanent(fileId: String, reason: String) async throws

    /// Annule une suppression en file qui n'a pas encore touché l'API (state
    /// `.queued`). No-op si l'item est dans un autre état (déjà parti côté
    /// serveur → on ne peut plus le ressusciter ici).
    func cancelDeletion(fileId: String) async throws

    /// Re-enqueue forcée d'un item `.failedPermanent` — action "Réessayer".
    func requeueDeletion(fileId: String) async throws

    /// Sweep : réinitialise tous les items bloqués en `.deleting` vers
    /// `.queued`. Cas crash mi-deletion. Retourne le nombre d'items reset.
    @discardableResult
    func resetOrphanedDeletions() async throws -> Int
}

public struct DeletionRequest: Sendable {
    public let fileId: String
    public let driveId: Int
    public let localIdentifier: String
    public init(fileId: String, driveId: Int, localIdentifier: String) {
        self.fileId = fileId; self.driveId = driveId; self.localIdentifier = localIdentifier
    }
}

public typealias DeletionQueueing = DeletionQueueReading & DeletionQueueWriting
