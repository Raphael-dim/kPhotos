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
public final class AlbumsViewModel: ObservableObject {
    public enum State: Equatable {
        case loading
        case noDriveSelected
        case empty
        case ready(albums: [AlbumSnapshot])
        case error(message: String)
    }

    @Published public private(set) var state: State = .loading

    @InjectService private var albums: AlbumManaging
    @InjectService private var drives: DriveManaging

    public init() {}

    public func load() async {
        do {
            guard let drive = try drives.selectedDrive() else {
                state = .noDriveSelected
                return
            }
            // Source de vérité = serveur. On synchronise puis on lit Realm.
            try await albums.refreshAlbums(driveId: drive.id)
            let snapshots = try albums.allAlbums()
            state = snapshots.isEmpty ? .empty : .ready(albums: snapshots)
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    public func createAlbum(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            guard let drive = try drives.selectedDrive() else {
                state = .noDriveSelected
                return
            }
            _ = try await albums.createAlbum(driveId: drive.id, name: trimmed)
            await load()
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    public func renameAlbum(albumId: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            guard let drive = try drives.selectedDrive() else {
                state = .noDriveSelected
                return
            }
            _ = try await albums.renameAlbum(albumId: albumId, driveId: drive.id, name: trimmed)
            await load()
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    /// Supprime l'album (= la catégorie kDrive). Les fichiers ne sont **pas**
    /// touchés : `deleteCategory` retire seulement le libellé.
    public func deleteAlbum(albumId: String) async {
        do {
            guard let drive = try drives.selectedDrive() else {
                state = .noDriveSelected
                return
            }
            try await albums.deleteAlbum(albumId: albumId, driveId: drive.id)
            await load()
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }
}
