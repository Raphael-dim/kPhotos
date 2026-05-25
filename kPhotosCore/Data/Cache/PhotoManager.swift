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
 */

import Foundation
import RealmSwift

// Interface Segregation : on expose lecture et écriture séparément.
// Toutes les méthodes renvoient des `PhotoSnapshot` (value type) — JAMAIS un Photo Realm
// managé qui crasherait au franchissement d'une frontière async (cf. AGENTS.md §21).

public protocol PhotoReading: AnyObject {
    func photo(byFileId fileId: String) throws -> PhotoSnapshot?
    func photo(byLocalIdentifier localIdentifier: String) throws -> PhotoSnapshot?
    func allPhotos() throws -> [PhotoSnapshot]
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
    func updateSyncStatus(fileId: String, status: PhotoSyncStatus) async throws
    func setFavorite(fileId: String, isFavorite: Bool) async throws
    func delete(fileId: String) async throws
}

/// File de sauvegarde persistante. Indexée par `localIdentifier` du PHAsset.
/// Cf. `BackupItem` pour la sémantique du state machine.
public protocol BackupQueueReading: AnyObject {
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

public protocol BackupQueueWriting: AnyObject {
    /// Ajoute un asset s'il n'est pas déjà en file. No-op si un item existe déjà
    /// pour ce `localIdentifier` (quel que soit son état) — la dédup est gérée
    /// par la clé primaire Realm + ce garde-fou.
    /// Génère un `clientToken` UUID stable persisté pour la vie de l'item.
    func enqueueIfAbsent(localIdentifier: String,
                         creationDate: Date,
                         isVideo: Bool) async throws

    /// Transitions de state machine. Garantit l'atomicité d'une bascule
    /// state + métadonnées associées (lastAttemptAt, lastErrorReason, attemptCount).
    func markUploading(localIdentifier: String) async throws
    func markCompleted(localIdentifier: String) async throws
    /// Marque l'item comme échec transient avec date de prochaine tentative.
    /// Le worker reprendra cet item dès que `now() >= nextRetryAt` au prochain
    /// coup de moteur (sync manuelle ou BG). Ne réinitialise PAS `attemptCount` —
    /// permet au classifier d'allonger le backoff sur les retries successifs.
    func markFailedTransient(localIdentifier: String,
                             reason: String,
                             nextRetryAt: Date) async throws
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
    /// Enqueue une suppression. No-op si un item existe déjà pour ce `fileId`
    /// (sauf s'il était en `.failedPermanent` — auquel cas on le re-queue,
    /// l'utilisateur a explicitement re-déclenché la suppression).
    func enqueueDeletion(fileId: String,
                         driveId: Int,
                         localIdentifier: String) async throws

    func markDeleting(fileId: String) async throws
    /// Marque comme `.completed` ET supprime le `Photo` Realm correspondant.
    /// Transaction unique → l'UI ne peut jamais observer un état intermédiaire
    /// "photo encore présente, suppression complète". Purge aussi l'entry
    /// DeletionItem (l'historique des completed n'a aucune utilité).
    func markDeletionCompleted(fileId: String) async throws
    func markDeletionFailedTransient(fileId: String,
                                     reason: String,
                                     nextRetryAt: Date) async throws
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

public typealias DeletionQueueing = DeletionQueueReading & DeletionQueueWriting

public final class PhotoManagerImpl: PhotoReading, PhotoWriting, BackupQueueReading, BackupQueueWriting, DeletionQueueReading, DeletionQueueWriting {
    private let realm: RealmAccessor

    public init(realm: RealmAccessor) {
        self.realm = realm
    }

    // MARK: - PhotoReading

    public func photo(byFileId fileId: String) throws -> PhotoSnapshot? {
        try realm.read { realm in
            realm.object(ofType: Photo.self, forPrimaryKey: fileId).map(PhotoSnapshot.init)
        }
    }

    public func photo(byLocalIdentifier localIdentifier: String) throws -> PhotoSnapshot? {
        try realm.read { realm in
            realm.objects(Photo.self)
                .filter("localIdentifier == %@", localIdentifier)
                .first
                .map(PhotoSnapshot.init)
        }
    }

    public func allPhotos() throws -> [PhotoSnapshot] {
        try realm.read { realm in
            realm.objects(Photo.self)
                .sorted(byKeyPath: "takenAt", ascending: false)
                .map(PhotoSnapshot.init)
        }
    }

    // MARK: - PhotoWriting

    public func upsert(_ snapshot: PhotoSnapshot) async throws {
        try await realm.write { realm in
            let photo = Self.makePhoto(from: snapshot)
            realm.add(photo, update: .modified)
        }
    }

    public func upsert(_ snapshots: [PhotoSnapshot]) async throws {
        try await realm.write { realm in
            let photos = snapshots.map(Self.makePhoto(from:))
            realm.add(photos, update: .modified)
        }
    }

    public func upsertFromListing(_ snapshots: [PhotoSnapshot]) async throws {
        try await realm.write { realm in
            for snapshot in snapshots {
                let photo = Self.makePhoto(from: snapshot)
                let existing = realm.object(ofType: Photo.self, forPrimaryKey: snapshot.id)

                // Reconstruction du `localIdentifier` : ordre de préférence
                // 1. Le listing en a un (rare — le serveur ne le renvoie pas)
                // 2. Le record Realm existant en a un (cas standard après upload)
                // 3. Parsing du nom de fichier (récupération des records corrompus
                //    par d'anciens upserts qui avaient écrasé le champ)
                if photo.localIdentifier.isEmpty {
                    if let existing, !existing.localIdentifier.isEmpty {
                        photo.localIdentifier = existing.localIdentifier
                    } else if let recovered = Self.recoverLocalIdentifier(from: snapshot.name) {
                        photo.localIdentifier = recovered
                    }
                }

                // Champs client-side absents du listing — on garde l'existant.
                if let existing {
                    photo.isFavorite = existing.isFavorite
                    photo.albumIds.removeAll()
                    photo.albumIds.append(objectsIn: existing.albumIds)
                }

                realm.add(photo, update: .modified)
            }
        }
    }

    public func updateSyncStatus(fileId: String, status: PhotoSyncStatus) async throws {
        try await realm.write { realm in
            guard let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId) else { return }
            photo.syncStatusRaw = status.rawValue
        }
    }

    public func setFavorite(fileId: String, isFavorite: Bool) async throws {
        try await realm.write { realm in
            guard let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId) else { return }
            photo.isFavorite = isFavorite
        }
    }

    public func delete(fileId: String) async throws {
        try await realm.write { realm in
            guard let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId) else { return }
            realm.delete(photo)
        }
    }

    // MARK: - BackupQueueReading

    public func allItems() throws -> [BackupItemSnapshot] {
        try realm.read { realm in
            realm.objects(BackupItem.self).map(BackupItemSnapshot.init)
        }
    }

    public func nextProcessable(now: Date, limit: Int?) throws -> [BackupItemSnapshot] {
        try realm.read { realm in
            // Predicate :
            //   state == queued
            //   OR (state == failedTransient AND nextRetryAt <= now)
            // Realm NSPredicate format ne supporte pas `nextRetryAt <= nil` propre,
            // mais notre invariant : `.failedTransient` ⇒ `nextRetryAt != nil` (cf.
            // `markFailedTransient`). Donc on peut comparer sans guard.
            let processable = realm.objects(BackupItem.self)
                .filter("stateRaw == %@ OR (stateRaw == %@ AND nextRetryAt <= %@)",
                        BackupItemState.queued.rawValue,
                        BackupItemState.failedTransient.rawValue,
                        now as NSDate)
                .sorted(byKeyPath: "creationDate", ascending: false)
            if let limit {
                return processable.prefix(limit).map(BackupItemSnapshot.init)
            }
            return processable.map(BackupItemSnapshot.init)
        }
    }

    public func item(localIdentifier: String) throws -> BackupItemSnapshot? {
        try realm.read { realm in
            realm.object(ofType: BackupItem.self, forPrimaryKey: localIdentifier)
                .map(BackupItemSnapshot.init)
        }
    }

    public func completedLocalIdentifiers() throws -> Set<String> {
        try realm.read { realm in
            Set(realm.objects(BackupItem.self)
                .filter("stateRaw == %@", BackupItemState.completed.rawValue)
                .map(\.localIdentifier))
        }
    }

    // MARK: - BackupQueueWriting

    public func enqueueIfAbsent(localIdentifier: String,
                                creationDate: Date,
                                isVideo: Bool) async throws {
        guard !localIdentifier.isEmpty else { return }
        try await realm.write { realm in
            if realm.object(ofType: BackupItem.self, forPrimaryKey: localIdentifier) != nil {
                return // déjà connu — le reconciler est idempotent par design
            }
            let item = BackupItem()
            item.localIdentifier = localIdentifier
            item.state = .queued
            // UUID stable, persisté pour toute la vie de l'item. Cf. doc API :
            // permet au serveur de dédupliquer un retry après réponse perdue.
            item.clientToken = UUID().uuidString
            item.enqueuedAt = Date()
            item.creationDate = creationDate
            item.isVideo = isVideo
            realm.add(item)
        }
    }

    public func markUploading(localIdentifier: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .uploading
            entity.lastAttemptAt = Date()
            entity.attemptCount += 1
            // En entrant en `.uploading` on n'a plus de raison d'avoir un
            // `nextRetryAt` actif — il sera repositionné si l'upload échoue.
            entity.nextRetryAt = nil
        }
    }

    public func markCompleted(localIdentifier: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .completed
            entity.lastErrorReason = ""
            entity.nextRetryAt = nil
        }
    }

    public func markFailedTransient(localIdentifier: String,
                                    reason: String,
                                    nextRetryAt: Date) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .failedTransient
            entity.lastErrorReason = reason
            entity.nextRetryAt = nextRetryAt
        }
    }

    public func markFailedPermanent(localIdentifier: String, reason: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .failedPermanent
            entity.lastErrorReason = reason
            entity.nextRetryAt = nil
        }
    }

    public func markSkipped(localIdentifier: String, reason: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .skipped
            entity.lastErrorReason = reason
            entity.nextRetryAt = nil
        }
    }

    public func requeue(localIdentifier: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .queued
            entity.lastErrorReason = ""
            entity.nextRetryAt = nil
            // `attemptCount` est PRÉSERVÉ — un requeue manuel après plusieurs
            // échecs reste tracé. Si le user re-tente et ça échoue à nouveau,
            // le classifier appliquera le bon palier de backoff.
            // `clientToken` est PRÉSERVÉ — c'est ce qui rend le retry idempotent
            // côté kDrive (le serveur dédupe).
        }
    }

    @discardableResult
    public func requeueAllPermanentlyFailed() async throws -> Int {
        try await realm.writeReturning { realm -> Int in
            let failed = realm.objects(BackupItem.self)
                .filter("stateRaw == %@", BackupItemState.failedPermanent.rawValue)
            var count = 0
            for entity in failed {
                entity.state = .queued
                entity.lastErrorReason = ""
                entity.nextRetryAt = nil
                count += 1
            }
            return count
        }
    }

    @discardableResult
    public func resetOrphanedUploads() async throws -> Int {
        try await realm.writeReturning { realm -> Int in
            let orphaned = realm.objects(BackupItem.self)
                .filter("stateRaw == %@", BackupItemState.uploading.rawValue)
            var count = 0
            for entity in orphaned {
                entity.state = .queued
                // `attemptCount` est PRÉSERVÉ — l'item garde la trace des
                // tentatives passées. `clientToken` aussi — l'upload qui avait
                // peut-être réussi côté serveur sera dédupliqué au retry.
                count += 1
            }
            return count
        }
    }

    // MARK: - DeletionQueueReading

    public func allDeletions() throws -> [DeletionItemSnapshot] {
        try realm.read { realm in
            realm.objects(DeletionItem.self).map(DeletionItemSnapshot.init)
        }
    }

    public func nextDeletable(now: Date, limit: Int?) throws -> [DeletionItemSnapshot] {
        try realm.read { realm in
            // Même predicate-pattern que `nextProcessable` côté BackupItem :
            //   state == queued OR (state == failedTransient AND nextRetryAt <= now)
            // Invariant `failedTransient ⇒ nextRetryAt != nil` (cf. `markDeletionFailedTransient`).
            let processable = realm.objects(DeletionItem.self)
                .filter("stateRaw == %@ OR (stateRaw == %@ AND nextRetryAt <= %@)",
                        DeletionItemState.queued.rawValue,
                        DeletionItemState.failedTransient.rawValue,
                        now as NSDate)
                .sorted(byKeyPath: "enqueuedAt", ascending: true)
            if let limit {
                return processable.prefix(limit).map(DeletionItemSnapshot.init)
            }
            return processable.map(DeletionItemSnapshot.init)
        }
    }

    public func deletionItem(fileId: String) throws -> DeletionItemSnapshot? {
        try realm.read { realm in
            realm.object(ofType: DeletionItem.self, forPrimaryKey: fileId)
                .map(DeletionItemSnapshot.init)
        }
    }

    public func pendingDeletionFileIds() throws -> Set<String> {
        try realm.read { realm in
            Set(realm.objects(DeletionItem.self).map(\.fileId))
        }
    }

    // MARK: - DeletionQueueWriting

    public func enqueueDeletion(fileId: String,
                                driveId: Int,
                                localIdentifier: String) async throws {
        guard !fileId.isEmpty else { return }
        try await realm.write { realm in
            if let existing = realm.object(ofType: DeletionItem.self, forPrimaryKey: fileId) {
                // Si l'item existait en `.failedPermanent`, on re-déclenche : c'est
                // équivalent à un "Réessayer". Sinon (queued/deleting/failedTransient)
                // on no-op pour rester idempotent.
                if existing.state == .failedPermanent {
                    existing.state = .queued
                    existing.lastErrorReason = ""
                    existing.nextRetryAt = nil
                }
                return
            }
            let item = DeletionItem()
            item.fileId = fileId
            item.driveId = driveId
            item.localIdentifier = localIdentifier
            item.state = .queued
            item.enqueuedAt = Date()
            realm.add(item)
        }
    }

    public func markDeleting(fileId: String) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .deleting
            entity.lastAttemptAt = Date()
            entity.attemptCount += 1
            entity.nextRetryAt = nil
        }
    }

    public func markDeletionCompleted(fileId: String) async throws {
        guard !fileId.isEmpty else { return }
        try await realm.write { realm in
            // Transaction unique : on supprime le Photo ET on purge le DeletionItem.
            // Si on séparait les deux, l'UI pourrait observer un état "photo
            // toujours présente, deletion item completed mais pas encore purgé".
            if let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId) {
                realm.delete(photo)
            }
            if let entity = realm.object(ofType: DeletionItem.self, forPrimaryKey: fileId) {
                realm.delete(entity)
            }
        }
    }

    public func markDeletionFailedTransient(fileId: String,
                                            reason: String,
                                            nextRetryAt: Date) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .failedTransient
            entity.lastErrorReason = reason
            entity.nextRetryAt = nextRetryAt
        }
    }

    public func markDeletionFailedPermanent(fileId: String, reason: String) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .failedPermanent
            entity.lastErrorReason = reason
            entity.nextRetryAt = nil
        }
    }

    public func cancelDeletion(fileId: String) async throws {
        guard !fileId.isEmpty else { return }
        try await realm.write { realm in
            guard let entity = realm.object(ofType: DeletionItem.self, forPrimaryKey: fileId) else { return }
            // On n'annule que ce qui n'a pas encore touché le réseau. Une fois
            // l'item parti en `.deleting` la requête est en vol et on ne peut
            // plus garantir la cohérence — l'utilisateur devrait re-upload pour
            // restaurer (hors de scope ici).
            guard entity.state == .queued else { return }
            realm.delete(entity)
        }
    }

    public func requeueDeletion(fileId: String) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .queued
            entity.lastErrorReason = ""
            entity.nextRetryAt = nil
        }
    }

    @discardableResult
    public func resetOrphanedDeletions() async throws -> Int {
        try await realm.writeReturning { realm -> Int in
            let orphaned = realm.objects(DeletionItem.self)
                .filter("stateRaw == %@", DeletionItemState.deleting.rawValue)
            var count = 0
            for entity in orphaned {
                entity.state = .queued
                count += 1
            }
            return count
        }
    }

    /// Helper mutateur DeletionItem — pendant du `mutate` côté BackupItem.
    private func mutateDeletion(fileId: String,
                                _ block: @escaping (DeletionItem) -> Void) async throws {
        guard !fileId.isEmpty else { return }
        try await realm.write { realm in
            guard let entity = realm.object(ofType: DeletionItem.self,
                                            forPrimaryKey: fileId) else { return }
            block(entity)
        }
    }

    /// Helper mutateur : applique un block sur l'entité gérée si elle existe.
    /// No-op silencieux si l'item a disparu (asset supprimé localement entre-temps).
    private func mutate(localIdentifier: String,
                        _ block: @escaping (BackupItem) -> Void) async throws {
        guard !localIdentifier.isEmpty else { return }
        try await realm.write { realm in
            guard let entity = realm.object(ofType: BackupItem.self,
                                            forPrimaryKey: localIdentifier) else { return }
            block(entity)
        }
    }

    /// Tente de reconstruire le `localIdentifier` PHAsset à partir du nom de fichier
    /// généré par `PHAssetExporter.makeFileName` : `yyyyMMdd_HHmmss_<id>.<ext>`
    /// où `<id>` est le `localIdentifier` avec ses `/` remplacés par `-`.
    ///
    /// Cas standard pour un UUID + suffixe PhotoKit :
    /// `20200101_000000_B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A-L0-001.jpg`
    /// →
    /// `B8AF98C0-0EAD-4555-BD9C-94BCEFD7A29A/L0/001`
    ///
    /// Retourne `nil` quand le pattern ne matche pas (= fichier uploadé hors-app,
    /// par exemple via le web kDrive) — la photo reste alors `cloudOnly` côté UI.
    /// Usage : récupération des records corrompus par d'anciens upserts (Phase 2 du fix dédup).
    static func recoverLocalIdentifier(from fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        let parts = stem.components(separatedBy: "_")
        guard parts.count >= 3 else { return nil }
        // Préfixe daté `yyyyMMdd_HHmmss` strictement numérique — sinon ce n'est pas
        // un fichier exporté par notre app, on n'essaie pas de deviner.
        guard parts[0].count == 8, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].count == 6, parts[1].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        // `joined(separator: "_")` au cas où le `localIdentifier` contiendrait
        // un `_` (rare mais autorisé par PhotoKit).
        let sanitized = parts.dropFirst(2).joined(separator: "_")
        // PHAsset.localIdentifier = `<UUID>/L0/001` typiquement. L'UUID a exactement
        // 4 tirets (5 segments). Les tirets suivants étaient des `/`.
        let segments = sanitized.components(separatedBy: "-")
        guard segments.count >= 5 else { return nil }
        let uuid = segments.prefix(5).joined(separator: "-")
        let suffix = segments.dropFirst(5)
        if suffix.isEmpty { return uuid }
        return uuid + "/" + suffix.joined(separator: "/")
    }

    /// Construit un Photo (unmanaged) à partir d'un snapshot. À appeler à l'intérieur d'un
    /// block `realm.write`, juste avant `realm.add(photo, update: .modified)`.
    static func makePhoto(from snapshot: PhotoSnapshot) -> Photo {
        let photo = Photo()
        photo.fileId = snapshot.id
        photo.driveId = snapshot.driveId
        photo.localIdentifier = snapshot.localIdentifier
        photo.name = snapshot.name
        photo.takenAt = snapshot.takenAt
        photo.uploadedAt = snapshot.uploadedAt
        photo.mimeType = snapshot.mimeType
        photo.size = snapshot.size
        photo.isVideo = snapshot.isVideo
        photo.duration = snapshot.duration
        photo.albumIds.removeAll()
        photo.albumIds.append(objectsIn: snapshot.albumIds)
        photo.syncStatusRaw = snapshot.syncStatus.rawValue
        photo.isFavorite = snapshot.isFavorite
        return photo
    }
}
