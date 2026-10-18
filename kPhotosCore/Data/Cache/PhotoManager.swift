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

public final class PhotoManagerImpl: PhotoReading, PhotoWriting, BackupQueueReading, BackupQueueWriting, DeletionQueueReading,
    DeletionQueueWriting {
    let realm: RealmAccessor

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

    public var changesPublisher: AnyPublisher<Void, Never> {
        do {
            let results = try Realm(configuration: realm.configuration).objects(Photo.self)
            return results.collectionPublisher
                .map { _ in () }
                .replaceError(with: ())
                .eraseToAnyPublisher()
        } catch {
            // Database errors remain visible through the throwing read methods.
            return Empty().eraseToAnyPublisher()
        }
    }

    // MARK: - PhotoWriting

    public func upsert(_ snapshot: PhotoSnapshot) async throws {
        try await realm.write { realm in
            let photo = try Self.makePhoto(from: snapshot)
            realm.add(photo, update: .modified)
        }
    }

    public func upsert(_ snapshots: [PhotoSnapshot]) async throws {
        try await realm.write { realm in
            let photos = try snapshots.map(Self.makePhoto(from:))
            realm.add(photos, update: .modified)
        }
    }

    public func commitListing(
        _ snapshots: [PhotoSnapshot],
        driveId: Int,
        folderId: String,
        fileIds: Set<String>,
        revisions: [String: String]
    ) async throws {
        try await realm.write { realm in
            // A completed scan only hides stale cache entries; it never deletes user data.
            for existing in realm.objects(Photo.self).filter("driveId == %@ AND libraryRootId == %@", driveId, folderId) {
                existing.isAvailable = false
            }
            for snapshot in snapshots {
                let photo = try Self.makePhoto(from: snapshot)
                if let existing = realm.object(ofType: Photo.self, forPrimaryKey: snapshot.id), existing.driveId == driveId {
                    if photo.remoteRevision == existing.remoteRevision {
                        photo.thumbnailPackJSON = existing.thumbnailPackJSON
                        photo.embeddedMetadataJSON = existing.embeddedMetadataJSON
                        photo.embeddedMetadataRevision = existing.embeddedMetadataRevision
                        if let embedded = PhotoSnapshot(existing).embeddedMetadata {
                            photo.latitude = embedded.coordinate?.latitude
                            photo.longitude = embedded.coordinate?.longitude
                            photo.locationSource = embedded.coordinate == nil ? "" : "embedded"
                            if let date = embedded.captureDate {
                                photo.takenAt = date
                                photo.captureDateSource = embedded.hasExplicitTimezone ? "embedded_offset" : "embedded_local"
                            }
                        } else if existing.locationSource == "photokit" {
                            photo.latitude = existing.latitude
                            photo.longitude = existing.longitude
                            photo.locationSource = existing.locationSource
                        }
                    }
                    photo.localIdentifier = existing.localIdentifier
                    photo.isFavorite = existing.isFavorite
                    photo.albumIds.removeAll()
                    photo.albumIds.append(objectsIn: existing.albumIds)
                    photo.resourceRevisionsJSON = existing.resourceRevisionsJSON
                    photo.localModifiedAt = existing.localModifiedAt
                    photo.resourceFileIds.removeAll()
                    photo.resourceFileIds.append(objectsIn: existing.resourceFileIds)
                    photo.backupComplete = existing.backupComplete && !existing.resourceFileIds.isEmpty
                        && Set(existing.resourceFileIds).isSubset(of: fileIds)
                    let expected = PhotoSnapshot(existing).resourceRevisions
                    photo.backupComplete = photo.backupComplete && !expected.isEmpty
                        && expected.allSatisfy { !$0.value.isEmpty && revisions[$0.key] == $0.value }
                    if photo.contentSHA256.isEmpty,
                       photo.remoteRevision == existing.remoteRevision { photo.contentSHA256 = existing.contentSHA256 }
                    if !existing.localIdentifier.isEmpty {
                        photo.takenAt = existing.takenAt
                        photo.captureDateSource = "photokit"
                    }
                }
                photo.libraryRootId = folderId
                photo.isAvailable = true
                realm.add(photo, update: .modified)
            }
        }
    }

    public func upsertFromListing(_ snapshots: [PhotoSnapshot]) async throws {
        try await realm.write { realm in
            for snapshot in snapshots {
                let photo = try Self.makePhoto(from: snapshot)
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
                    if photo.locationSource.isEmpty, photo.remoteRevision == existing.remoteRevision {
                        photo.thumbnailPackJSON = existing.thumbnailPackJSON
                        photo.embeddedMetadataJSON = existing.embeddedMetadataJSON
                        photo.embeddedMetadataRevision = existing.embeddedMetadataRevision
                        photo.latitude = existing.latitude
                        photo.longitude = existing.longitude
                        photo.locationSource = existing.locationSource
                    }
                    photo.libraryRootId = existing.libraryRootId
                    photo.isAvailable = existing.isAvailable
                    photo.contentSHA256 = existing.contentSHA256
                    photo.backupComplete = existing.backupComplete
                    photo.resourceRevisionsJSON = existing.resourceRevisionsJSON
                    photo.localModifiedAt = existing.localModifiedAt
                    photo.resourceFileIds.removeAll()
                    photo.resourceFileIds.append(objectsIn: existing.resourceFileIds)
                    if !existing.localIdentifier.isEmpty {
                        photo.takenAt = existing.takenAt
                        photo.captureDateSource = "photokit"
                    }
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

    // MARK: - Snapshot mapping

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
              parts[1].count == 6, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
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
    static func makePhoto(from snapshot: PhotoSnapshot) throws -> Photo {
        let photo = Photo()
        photo.fileId = snapshot.id
        photo.driveId = snapshot.driveId
        photo.localIdentifier = snapshot.localIdentifier
        photo.name = snapshot.name
        photo.takenAt = snapshot.takenAt
        photo.captureDateSource = snapshot.captureDateSource
        photo.latitude = snapshot.coordinate?.latitude
        photo.longitude = snapshot.coordinate?.longitude
        photo.locationSource = snapshot.locationSource
        photo.thumbnailPackJSON = snapshot.thumbnailPack
            .flatMap { try? Self.encodeJSON($0) } ?? ""
        photo.embeddedMetadataJSON = snapshot.embeddedMetadataJSON
        photo.embeddedMetadataRevision = snapshot.embeddedMetadataRevision
        photo.uploadedAt = snapshot.uploadedAt
        photo.mimeType = snapshot.mimeType
        photo.size = snapshot.size
        photo.isVideo = snapshot.isVideo
        photo.duration = snapshot.duration
        photo.albumIds.removeAll()
        photo.albumIds.append(objectsIn: snapshot.albumIds)
        photo.syncStatusRaw = snapshot.syncStatus.rawValue
        photo.isFavorite = snapshot.isFavorite
        photo.libraryRootId = snapshot.libraryRootId
        photo.isAvailable = snapshot.isAvailable
        photo.contentSHA256 = snapshot.contentSHA256
        photo.remoteRevision = snapshot.remoteRevision
        photo.localModifiedAt = snapshot.localModifiedAt
        photo.resourceRevisionsJSON = try Self.encodeJSON(snapshot.resourceRevisions)
        photo.backupComplete = snapshot.backupComplete
        photo.resourceFileIds.append(objectsIn: snapshot.resourceFileIds)
        return photo
    }
}
