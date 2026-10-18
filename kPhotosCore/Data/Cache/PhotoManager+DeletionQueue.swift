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
    func allDeletions() throws -> [DeletionItemSnapshot] {
        try realm.read { realm in
            realm.objects(DeletionItem.self).map(DeletionItemSnapshot.init)
        }
    }

    func nextDeletable(now: Date, limit: Int?) throws -> [DeletionItemSnapshot] {
        try realm.read { realm in
            // Même predicate-pattern que `nextProcessable` côté BackupItem :
            //   state == queued OR (state == failedTransient AND nextRetryAt <= now)
            // Invariant `failedTransient ⇒ nextRetryAt != nil` (cf. `markDeletionFailedTransient`).
            let processable = realm.objects(DeletionItem.self)
                .filter(
                    "stateRaw == %@ OR (stateRaw == %@ AND nextRetryAt <= %@)",
                    DeletionItemState.queued.rawValue,
                    DeletionItemState.failedTransient.rawValue,
                    now as NSDate
                )
                .sorted(byKeyPath: "enqueuedAt", ascending: true)
            if let limit {
                return processable.prefix(limit).map(DeletionItemSnapshot.init)
            }
            return processable.map(DeletionItemSnapshot.init)
        }
    }

    func deletionItem(fileId: String) throws -> DeletionItemSnapshot? {
        try realm.read { realm in
            realm.object(ofType: DeletionItem.self, forPrimaryKey: fileId)
                .map(DeletionItemSnapshot.init)
        }
    }

    func pendingDeletionFileIds() throws -> Set<String> {
        try realm.read { realm in
            Set(realm.objects(DeletionItem.self).map(\.fileId))
        }
    }

    // MARK: - DeletionQueueWriting

    func enqueueDeletion(
        fileId: String,
        driveId: Int,
        localIdentifier: String
    ) async throws {
        try await enqueueDeletions([DeletionRequest(fileId: fileId, driveId: driveId, localIdentifier: localIdentifier)])
    }

    func enqueueDeletions(_ requests: [DeletionRequest]) async throws {
        try await realm.write { realm in
            for request in requests where !request.fileId.isEmpty {
                if let existing = realm.object(ofType: DeletionItem.self, forPrimaryKey: request.fileId) {
                    // Requeue explicit retries; other in-flight requests stay idempotent.
                    if existing.state == .failedPermanent {
                        existing.state = .queued
                        existing.lastErrorReason = ""
                        existing.nextRetryAt = nil
                    }
                    continue
                }
                let item = DeletionItem()
                item.fileId = request.fileId
                item.driveId = request.driveId
                item.localIdentifier = request.localIdentifier
                item.state = .queued
                item.enqueuedAt = Date()
                realm.add(item)
            }
        }
    }

    func markDeleting(fileId: String) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .deleting
            entity.lastAttemptAt = Date()
            entity.attemptCount += 1
            entity.nextRetryAt = nil
        }
    }

    func markDeletionCompleted(fileId: String) async throws {
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

    func markDeletionFailedTransient(
        fileId: String,
        reason: String,
        nextRetryAt: Date
    ) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .failedTransient
            entity.lastErrorReason = reason
            entity.nextRetryAt = nextRetryAt
        }
    }

    func markDeletionFailedPermanent(fileId: String, reason: String) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .failedPermanent
            entity.lastErrorReason = reason
            entity.nextRetryAt = nil
        }
    }

    func cancelDeletion(fileId: String) async throws {
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

    func requeueDeletion(fileId: String) async throws {
        try await mutateDeletion(fileId: fileId) { entity in
            entity.state = .queued
            entity.lastErrorReason = ""
            entity.nextRetryAt = nil
        }
    }

    @discardableResult
    func resetOrphanedDeletions() async throws -> Int {
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
    private func mutateDeletion(
        fileId: String,
        _ block: @escaping (DeletionItem) -> Void
    ) async throws {
        guard !fileId.isEmpty else { return }
        try await realm.write { realm in
            guard let entity = realm.object(
                ofType: DeletionItem.self,
                forPrimaryKey: fileId
            ) else { return }
            block(entity)
        }
    }
}
