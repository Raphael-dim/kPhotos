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
import kPhotosCore

extension TimelineViewModel {
    func reconcileBackupQueue() async {
        let generation = backupInventoryGeneration
        let scope = try? driveManager.selectedDrive()
        do {
            try await sync.reconcile()
            guard generation == backupInventoryGeneration, !Task.isCancelled else { return }
            let current = try driveManager.selectedDrive()
            guard current?.id == scope?.id, current?.rootFolderId == scope?.rootFolderId else { return }
            backupItems = try Self.indexByLocalId(backupQueue.allItems())
            hasReconciledBackup = true
            backupReadError = nil
        } catch {
            guard generation == backupInventoryGeneration, !Task.isCancelled else { return }
            hasReconciledBackup = false
            backupReadError = error.localizedDescription
        }
        if case .ready(let summary, _) = state { rebuildState(summary: summary) } else { updateBackupOverview() }
    }

    func bindToBackupStatus() {
        backupQueue.backupChangesPublisher
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                do {
                    backupItems = try Self.indexByLocalId(backupQueue.allItems())
                    backupReadError = nil
                } catch { backupReadError = error.localizedDescription }
                if case .ready(let summary, _) = state { rebuildState(summary: summary) }
            }
            .store(in: &cancellables)
        syncSettings.publisher
            .map(\.mediaFilter)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.photoLibraryObserver.restart()
                self?.refreshLocalBackupInventory()
            }
            .store(in: &cancellables)
        syncSettings.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateBackupOverview() }
            .store(in: &cancellables)
        photoLibraryObserver.changesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshLocalBackupInventory() }
            .store(in: &cancellables)
    }

    /// A new or edited local asset must invalidate the completed claim, including after foregrounding.
    func refreshLocalBackupInventory() {
        guard case .ready = state else { return }
        backupInventoryGeneration = UUID()
        hasReconciledBackup = false
        updateBackupOverview()
        localReloadTask?.cancel()
        localReloadTask = Task {
            let assets = await self.assetReader.fetchAssetSnapshots(filter: .both)
            guard !Task.isCancelled else { return }
            self.localAssets = assets
            await self.reconcileBackupQueue()
        }
    }

    func updateBackupOverview() {
        do {
            guard let drive = try driveManager.selectedDrive() else {
                backupOverview = BackupOverview()
                return
            }
            let running: Bool
            if case .running = syncState { running = true } else { running = false }
            let uploads = uploadQueue.currentScope == "\(drive.id):\(drive.rootFolderId)" ? uploadQueue.currentStates : [:]
            backupOverview = try .make(BackupOverviewInput(
                assets: localAssets,
                photos: cloudPhotos,
                queue: backupItems,
                uploads: uploads,
                driveId: drive.id,
                rootId: drive.rootFolderId,
                settings: syncSettings.current(),
                authorization: assetReader.currentAuthorization(),
                checked: hasReconciledBackup,
                running: running,
                error: backupReadError
            ))
        } catch {
            var overview = BackupOverview()
            overview.phase = .attention
            overview.errorMessage = error.localizedDescription
            backupOverview = overview
        }
    }

    /// Pull du listing kDrive → upsert dans Realm → rafraîchit l'état.
    /// Idempotent et silencieux côté erreurs (réseau, serveur) : on garde le cache
    /// local affiché. Utilisé par `load()` (background), `runSync()` (pull-then-push)
    /// et le pull-to-refresh de la `TimelineView`.
}
