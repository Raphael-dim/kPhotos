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

public extension PhotoManagerImpl {
    var backupChangesPublisher: AnyPublisher<Void, Never> {
        do {
            let results = try Realm(configuration: realm.configuration).objects(BackupItem.self)
            return results.collectionPublisher
                .map { _ in () }
                .replaceError(with: ())
                .eraseToAnyPublisher()
        } catch {
            // The status panel reports the error from its throwing queue read.
            return Empty().eraseToAnyPublisher()
        }
    }

    func allItems() throws -> [BackupItemSnapshot] {
        try realm.read { realm in
            realm.objects(BackupItem.self).map(BackupItemSnapshot.init)
        }
    }

    func nextProcessable(now: Date, limit: Int?) throws -> [BackupItemSnapshot] {
        try realm.read { realm in
            // Predicate :
            //   state == queued
            //   OR (state == failedTransient AND nextRetryAt <= now)
            // Realm NSPredicate format ne supporte pas `nextRetryAt <= nil` propre,
            // mais notre invariant : `.failedTransient` ⇒ `nextRetryAt != nil` (cf.
            // `markFailedTransient`). Donc on peut comparer sans guard.
            let processable = realm.objects(BackupItem.self)
                .filter(
                    "stateRaw == %@ OR (stateRaw == %@ AND nextRetryAt <= %@)",
                    BackupItemState.queued.rawValue,
                    BackupItemState.failedTransient.rawValue,
                    now as NSDate
                )
                .sorted(byKeyPath: "creationDate", ascending: false)
            if let limit {
                return processable.prefix(limit).map(BackupItemSnapshot.init)
            }
            return processable.map(BackupItemSnapshot.init)
        }
    }

    func item(localIdentifier: String) throws -> BackupItemSnapshot? {
        try realm.read { realm in
            realm.object(ofType: BackupItem.self, forPrimaryKey: localIdentifier)
                .map(BackupItemSnapshot.init)
        }
    }

    func completedLocalIdentifiers() throws -> Set<String> {
        try realm.read { realm in
            Set(
                realm.objects(BackupItem.self)
                    .filter("stateRaw == %@", BackupItemState.completed.rawValue)
                    .map(\.localIdentifier)
            )
        }
    }

    // MARK: - BackupQueueWriting

    func reconcile(localAssets: [LocalAssetSnapshot], syncedIdentifiers: Set<String>) async throws {
        try await realm.write { realm in
            let completed = Array(
                realm.objects(BackupItem.self)
                    .filter("stateRaw == %@", BackupItemState.completed.rawValue)
            )
            for item in completed where !syncedIdentifiers.contains(item.localIdentifier) {
                item.state = .queued
                item.lastErrorReason = ""
                item.nextRetryAt = nil
            }

            for asset in localAssets where !asset.localIdentifier.isEmpty
                && !syncedIdentifiers.contains(asset.localIdentifier) {
                guard realm.object(ofType: BackupItem.self, forPrimaryKey: asset.localIdentifier) == nil else { continue }
                let item = BackupItem()
                item.localIdentifier = asset.localIdentifier
                item.state = .queued
                item.clientToken = UUID().uuidString
                item.enqueuedAt = Date()
                item.creationDate = asset.takenAt
                item.isVideo = asset.isVideo
                realm.add(item)
            }
        }
    }

    func enqueueIfAbsent(
        localIdentifier: String,
        creationDate: Date,
        isVideo: Bool
    ) async throws {
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

    func markUploading(localIdentifier: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .uploading
            entity.lastAttemptAt = Date()
            entity.attemptCount += 1
            // En entrant en `.uploading` on n'a plus de raison d'avoir un
            // `nextRetryAt` actif — il sera repositionné si l'upload échoue.
            entity.nextRetryAt = nil
        }
    }

    func markCompleted(localIdentifier: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .completed
            entity.lastErrorReason = ""
            entity.nextRetryAt = nil
        }
    }

    func markFailedTransient(
        localIdentifier: String,
        reason: String,
        nextRetryAt: Date
    ) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .failedTransient
            entity.lastErrorReason = reason
            entity.nextRetryAt = nextRetryAt
        }
    }

    func markFailedPermanent(localIdentifier: String, reason: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .failedPermanent
            entity.lastErrorReason = reason
            entity.nextRetryAt = nil
        }
    }

    func markSkipped(localIdentifier: String, reason: String) async throws {
        try await mutate(localIdentifier: localIdentifier) { entity in
            entity.state = .skipped
            entity.lastErrorReason = reason
            entity.nextRetryAt = nil
        }
    }

    func requeue(localIdentifier: String) async throws {
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
    func requeueAllPermanentlyFailed() async throws -> Int {
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
    func resetOrphanedUploads() async throws -> Int {
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

    // MARK: - Queue mutation

    /// Helper mutateur : applique un block sur l'entité gérée si elle existe.
    /// No-op silencieux si l'item a disparu (asset supprimé localement entre-temps).
    private func mutate(
        localIdentifier: String,
        _ block: @escaping (BackupItem) -> Void
    ) async throws {
        guard !localIdentifier.isEmpty else { return }
        try await realm.write { realm in
            guard let entity = realm.object(
                ofType: BackupItem.self,
                forPrimaryKey: localIdentifier
            ) else { return }
            block(entity)
        }
    }
}
