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
            let members = allPhotos.filter { $0.driveId == album.driveId && $0.isAvailable && $0.albumIds.contains(album.id) }
            let livePairs = LivePhotoPairing(photos: members)
            photos = members.filter { !livePairs.motionFileIds.contains($0.fileId) }
                .map { livePairs.attachMotion(to: $0) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addPhoto(fileId: String) async {
        let trimmed = fileId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let allPhotos = try photosReader.allPhotos().filter { $0.driveId == album.driveId }
            let pair = LivePhotoPairing(photos: allPhotos).motionByStillId[trimmed]
            try await albums.addPhotos(
                fileIds: [trimmed, pair?.fileId].compactMap { $0 }, toAlbumId: album.id, driveId: album.driveId
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removePhoto(fileId: String) async {
        do {
            try await albums.removePhoto(fileId: fileId, fromAlbumId: album.id, driveId: album.driveId)
            if let motionId = photos.first(where: { $0.fileId == fileId })?.liveMotionFileId {
                try await albums.removePhoto(fileId: motionId, fromAlbumId: album.id, driveId: album.driveId)
            }
            await load()
        } catch {
            await load()
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
