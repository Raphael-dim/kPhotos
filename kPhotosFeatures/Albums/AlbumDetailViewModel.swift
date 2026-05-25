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
import kPhotosCore

@MainActor
public final class AlbumDetailViewModel: ObservableObject {
    @Published public private(set) var photos: [PhotoSnapshot] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    /// `var` (et non `let`) pour que le titre de la vue suive un renommage.
    @Published public private(set) var album: AlbumSnapshot

    @InjectService private var albums: AlbumManaging
    @InjectService private var photosReader: PhotoReading

    public init(album: AlbumSnapshot) {
        self.album = album
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Pull du serveur pour rafraîchir les `Photo.albumIds` puis lecture locale.
            try await albums.refreshAlbumPhotos(albumId: album.id, driveId: album.driveId)
            let allPhotos = try photosReader.allPhotos()
            photos = allPhotos.filter { $0.albumIds.contains(album.id) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addPhoto(fileId: String) async {
        let trimmed = fileId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await albums.addPhotos(fileIds: [trimmed], toAlbumId: album.id, driveId: album.driveId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removePhoto(fileId: String) async {
        do {
            try await albums.removePhoto(fileId: fileId, fromAlbumId: album.id, driveId: album.driveId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func rename(to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != album.name else { return }
        do {
            album = try await albums.renameAlbum(albumId: album.id, driveId: album.driveId, name: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Supprime l'album (= la catégorie kDrive) — les photos qu'il contient ne
    /// sont **pas** supprimées. Renvoie `true` en cas de succès pour que la vue
    /// puisse dépiler la navigation.
    public func deleteAlbum() async -> Bool {
        do {
            try await albums.deleteAlbum(albumId: album.id, driveId: album.driveId)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
