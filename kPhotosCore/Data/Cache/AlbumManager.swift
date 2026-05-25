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
import RealmSwift

/// Gestion des albums kPhotos.
///
/// Modèle : un album = une **catégorie kDrive** (N:N entre fichiers et libellés).
/// Avantages vs anciens "vrais dossiers" :
/// - Une photo peut appartenir à plusieurs albums sans duplication.
/// - L'ajout n'altère pas l'organisation chronologique (pas de `move`).
/// - Bulk natif : N photos ajoutées en 1 appel API.
/// - Survit aux réorganisations externes (kDrive web, autre device).
///
/// Source de vérité : le serveur. Realm sert de cache local pour la lecture
/// instantanée — réconcilié à chaque `refreshAlbums` / `refreshAlbumPhotos`.
public protocol AlbumManaging: AnyObject {
    /// Lecture locale (Realm), synchrone, rapide. À appeler après un `refreshAlbums`
    /// pour avoir la liste à jour.
    func allAlbums() throws -> [AlbumSnapshot]
    func album(byId id: String) throws -> AlbumSnapshot?

    /// Tire la liste des catégories du drive, réconcilie le cache Realm.
    /// Supprime les albums obsolètes localement (catégorie disparue côté serveur
    /// — y compris ceux issus de l'ancienne implémentation à base de dossiers).
    func refreshAlbums(driveId: Int) async throws

    /// Tire la liste paginée des fichiers d'un album et met à jour `Photo.albumIds`
    /// localement. Idempotent.
    func refreshAlbumPhotos(albumId: String, driveId: Int) async throws

    func createAlbum(driveId: Int, name: String) async throws -> AlbumSnapshot
    func renameAlbum(albumId: String, driveId: Int, name: String) async throws -> AlbumSnapshot
    func deleteAlbum(albumId: String, driveId: Int) async throws

    /// Ajoute N photos à un album en 1 appel (bulk). À privilégier dès qu'on a
    /// >1 photo. Met à jour Realm après succès serveur.
    func addPhotos(fileIds: [String], toAlbumId albumId: String, driveId: Int) async throws

    /// Retire une photo d'un album. API + Realm.
    func removePhoto(fileId: String, fromAlbumId albumId: String, driveId: Int) async throws

    /// Résout (et persiste) l'`coverPhotoId` d'un album. Renvoie d'abord la valeur
    /// cachée si dispo, sinon fait un `listCategoryFiles(limit: 1)` pour la
    /// déterminer. Renvoie `nil` quand l'album est vide. Best-effort : pensé pour
    /// être appelé depuis une vue (échec API → cover absente, pas de throw).
    func resolveCover(albumId: String, driveId: Int) async throws -> String?
}

public final class AlbumManagerImpl: AlbumManaging {
    private let realm: RealmAccessor
    private let api: PhotoApiFetching

    public init(realm: RealmAccessor, api: PhotoApiFetching) {
        self.realm = realm
        self.api = api
    }

    // MARK: - Read

    public func allAlbums() throws -> [AlbumSnapshot] {
        try realm.read { realm in
            realm.objects(Album.self)
                .sorted(byKeyPath: "createdAt", ascending: false)
                .map(AlbumSnapshot.init)
        }
    }

    public func album(byId id: String) throws -> AlbumSnapshot? {
        try realm.read { realm in
            realm.object(ofType: Album.self, forPrimaryKey: id).map(AlbumSnapshot.init)
        }
    }

    // MARK: - Refresh (server → Realm)

    public func refreshAlbums(driveId: Int) async throws {
        let categories = try await api.listCategories(driveId: driveId)
        let serverIds = Set(categories.map { String($0.id) })

        try await realm.write { realm in
            // Upsert des catégories serveur. La PK ne se réécrit jamais sur un
            // objet managé (Realm throw : "Primary key can't be changed after
            // an object is inserted") → on assigne `id` uniquement pour les
            // nouvelles entrées avant l'`add`.
            for category in categories {
                let albumId = String(category.id)
                if let existing = realm.object(ofType: Album.self, forPrimaryKey: albumId) {
                    existing.driveId = driveId
                    existing.name = category.name
                    if category.createdAt > 0 {
                        existing.createdAt = Date(timeIntervalSince1970: TimeInterval(category.createdAt))
                    }
                } else {
                    let album = Album()
                    album.id = albumId
                    album.driveId = driveId
                    album.name = category.name
                    album.createdAt = category.createdAt > 0
                        ? Date(timeIntervalSince1970: TimeInterval(category.createdAt))
                        : Date()
                    realm.add(album)
                }
            }

            // Purge des albums locaux qui n'existent plus côté serveur (cleanup
            // automatique des entrées issues de l'ancienne implémentation dossier).
            let stale = realm.objects(Album.self)
                .filter("driveId == %@", driveId)
                .filter { !serverIds.contains($0.id) }
            for album in stale {
                // Nettoie aussi `Photo.albumIds` pour ne pas garder de références mortes.
                let albumId = album.id
                let affected = realm.objects(Photo.self).filter("ANY albumIds == %@", albumId)
                for photo in affected {
                    if let index = photo.albumIds.firstIndex(of: albumId) {
                        photo.albumIds.remove(at: index)
                    }
                }
                realm.delete(album)
            }
        }
    }

    public func refreshAlbumPhotos(albumId: String, driveId: Int) async throws {
        guard let categoryId = Int(albumId) else {
            throw PhotoAPIError.network(underlying: "albumId invalide: \(albumId)")
        }

        var cursor: String? = nil
        var orderedFileIds: [String] = []
        var serverFileIds: Set<String> = []
        repeat {
            let page = try await api.listCategoryFiles(driveId: driveId,
                                                       categoryId: categoryId,
                                                       cursor: cursor,
                                                       limit: 100)
            for item in page.items {
                orderedFileIds.append(item.id)
                serverFileIds.insert(item.id)
            }
            cursor = page.nextCursor
        } while cursor != nil

        try await realm.write { realm in
            // Ajoute la référence pour chaque photo locale présente côté serveur.
            for fileId in serverFileIds {
                guard let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId) else { continue }
                if !photo.albumIds.contains(albumId) {
                    photo.albumIds.append(albumId)
                }
            }
            // Retire la référence pour les photos qui l'avaient localement mais
            // ne sont plus dans la catégorie côté serveur.
            let drift = realm.objects(Photo.self).filter("ANY albumIds == %@", albumId)
            for photo in drift where !serverFileIds.contains(photo.fileId) {
                if let index = photo.albumIds.firstIndex(of: albumId) {
                    photo.albumIds.remove(at: index)
                }
            }
            // Met à jour le compteur + cover (= premier fichier renvoyé par le
            // serveur). Si l'ancienne cover a disparu côté serveur on bascule
            // sur la première dispo, sinon on garde celle déjà choisie pour
            // éviter de flasher la grille à chaque refresh.
            if let album = realm.object(ofType: Album.self, forPrimaryKey: albumId) {
                album.photoCount = serverFileIds.count
                if album.coverPhotoId.isEmpty || !serverFileIds.contains(album.coverPhotoId) {
                    album.coverPhotoId = orderedFileIds.first ?? ""
                }
            }
        }
    }

    // MARK: - Mutations

    public func createAlbum(driveId: Int, name: String) async throws -> AlbumSnapshot {
        let dto = try await api.createCategory(driveId: driveId, name: name, color: nil)

        let album = Album()
        album.id = String(dto.id)
        album.driveId = driveId
        album.name = dto.name
        album.createdAt = dto.createdAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(dto.createdAt))
            : Date()

        try await realm.write { realm in
            realm.add(album, update: .modified)
        }
        return AlbumSnapshot(album)
    }

    public func renameAlbum(albumId: String, driveId: Int, name: String) async throws -> AlbumSnapshot {
        guard let categoryId = Int(albumId) else {
            throw PhotoAPIError.network(underlying: "albumId invalide: \(albumId)")
        }
        let dto = try await api.updateCategory(driveId: driveId, categoryId: categoryId, name: name, color: nil)

        try await realm.write { realm in
            if let album = realm.object(ofType: Album.self, forPrimaryKey: albumId) {
                album.name = dto.name
            }
        }
        guard let snapshot = try album(byId: albumId) else {
            throw PhotoAPIError.network(underlying: "Album introuvable après renommage")
        }
        return snapshot
    }

    public func deleteAlbum(albumId: String, driveId: Int) async throws {
        guard let categoryId = Int(albumId) else {
            throw PhotoAPIError.network(underlying: "albumId invalide: \(albumId)")
        }
        try await api.deleteCategory(driveId: driveId, categoryId: categoryId)

        try await realm.write { realm in
            // Nettoie les références dans Photo.albumIds.
            let affected = realm.objects(Photo.self).filter("ANY albumIds == %@", albumId)
            for photo in affected {
                if let index = photo.albumIds.firstIndex(of: albumId) {
                    photo.albumIds.remove(at: index)
                }
            }
            if let album = realm.object(ofType: Album.self, forPrimaryKey: albumId) {
                realm.delete(album)
            }
        }
    }

    public func addPhotos(fileIds: [String], toAlbumId albumId: String, driveId: Int) async throws {
        guard !fileIds.isEmpty else { return }
        guard let categoryId = Int(albumId) else {
            throw PhotoAPIError.network(underlying: "albumId invalide: \(albumId)")
        }
        // Conversion String → Int au boundary (Photo.fileId est stocké en String
        // côté Realm, mais l'API attend des Int).
        let intFileIds = fileIds.compactMap(Int.init)
        guard intFileIds.count == fileIds.count else {
            throw PhotoAPIError.network(underlying: "fileId non numérique dans la sélection")
        }

        try await api.addCategoryToFiles(driveId: driveId, categoryId: categoryId, fileIds: intFileIds)

        try await realm.write { realm in
            for fileId in fileIds {
                guard let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId) else { continue }
                if !photo.albumIds.contains(albumId) {
                    photo.albumIds.append(albumId)
                }
            }
            if let album = realm.object(ofType: Album.self, forPrimaryKey: albumId) {
                album.photoCount = album.photoCount + fileIds.count
                // Album précédemment vide → la première photo ajoutée devient
                // la cover pour que la grille des albums se peuple immédiatement.
                if album.coverPhotoId.isEmpty, let first = fileIds.first {
                    album.coverPhotoId = first
                }
            }
        }
    }

    public func removePhoto(fileId: String, fromAlbumId albumId: String, driveId: Int) async throws {
        guard let categoryId = Int(albumId), let intFileId = Int(fileId) else {
            throw PhotoAPIError.network(underlying: "id invalide (fileId=\(fileId), albumId=\(albumId))")
        }
        try await api.removeCategoryFromFiles(driveId: driveId, categoryId: categoryId, fileIds: [intFileId])

        try await realm.write { realm in
            if let photo = realm.object(ofType: Photo.self, forPrimaryKey: fileId),
               let index = photo.albumIds.firstIndex(of: albumId) {
                photo.albumIds.remove(at: index)
            }
            if let album = realm.object(ofType: Album.self, forPrimaryKey: albumId) {
                if album.photoCount > 0 {
                    album.photoCount = album.photoCount - 1
                }
                // Cover supprimée → invalidée, sera reconstruite au prochain
                // `resolveCover` ou `refreshAlbumPhotos`.
                if album.coverPhotoId == fileId {
                    album.coverPhotoId = ""
                }
            }
        }
    }

    public func resolveCover(albumId: String, driveId: Int) async throws -> String? {
        // Cache hit : on évite l'appel réseau.
        if let cached = try realm.read({ realm in
            realm.object(ofType: Album.self, forPrimaryKey: albumId)?.coverPhotoId
        }), !cached.isEmpty {
            return cached
        }
        guard let categoryId = Int(albumId) else { return nil }
        let page = try await api.listCategoryFiles(driveId: driveId,
                                                   categoryId: categoryId,
                                                   cursor: nil,
                                                   limit: 1)
        guard let first = page.items.first else { return nil }

        try await realm.write { realm in
            if let album = realm.object(ofType: Album.self, forPrimaryKey: albumId) {
                album.coverPhotoId = first.id
            }
        }
        return first.id
    }
}
