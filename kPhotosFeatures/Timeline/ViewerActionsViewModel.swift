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

import kPhotosCore
import SwiftUI

// MARK: - ViewerActionsViewModel

@MainActor
final class ViewerActionsViewModel: ObservableObject {
    @Published private(set) var albums: [AlbumSnapshot] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDownloading = false

    @InjectService private var albumManager: AlbumManaging
    @InjectService private var driveManager: DriveManaging
    @InjectService private var downloader: MediaDownloading
    @InjectService private var deletionQueueWriter: DeletionQueueWriting
    @InjectService private var deletionEngine: PhotoDeleting

    func loadAlbums() async {
        if let drive = try? driveManager.selectedDrive() {
            try? await albumManager.refreshAlbums(driveId: drive.id)
        }
        albums = (try? albumManager.allAlbums()) ?? []
    }

    func addToAlbum(photo: PhotoSnapshot, albumId: String) async {
        do {
            let fileIds = [photo.fileId, photo.liveMotionFileId].compactMap { $0 }
            try await albumManager.addPhotos(fileIds: fileIds, toAlbumId: albumId, driveId: photo.driveId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(photo: PhotoSnapshot) async -> Bool {
        // Enqueue persistant + drain immédiat. Si le drain réussit, le `Photo`
        // Realm est purgé dans la même transaction que le DeletionItem — la
        // galerie reflètera la suppression dès le prochain rebuild. On retourne
        // `true` dès que l'enqueue est fait : la fermeture du viewer ne dépend
        // pas du succès réseau (sinon on bloquerait le UX en cas de mauvaise
        // connexion, alors que la file persistera et finira par drainer).
        do {
            var requests = [
                DeletionRequest(fileId: photo.fileId, driveId: photo.driveId, localIdentifier: photo.localIdentifier)
            ]
            if let motionId = photo.liveMotionFileId {
                requests.append(DeletionRequest(fileId: motionId, driveId: photo.driveId, localIdentifier: ""))
            }
            try await deletionQueueWriter.enqueueDeletions(requests)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        // Drain en best-effort. L'erreur éventuelle est capturée dans le
        // DeletionItem (state `.failedTransient/.failedPermanent`) — la
        // TimelineView lira les `lastDeletionFailures` à son prochain
        // `load()`/`refreshDeletionState`. On ne `await` pas ici pour que la
        // fermeture du viewer soit instantanée — `Task` hérite du main actor
        // mais `drain` est async et yieldera naturellement.
        Task {
            _ = await self.deletionEngine.drain { _ in }
        }
        return true
    }

    func download(photo: PhotoSnapshot) async -> Bool {
        guard !isDownloading else { return false }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let importedCount = try await downloader.downloadAndImport(photos: [photo], driveId: photo.driveId)
            return importedCount > 0
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
