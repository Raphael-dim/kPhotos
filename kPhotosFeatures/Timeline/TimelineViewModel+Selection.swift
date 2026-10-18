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

public extension TimelineViewModel {
    func toggleSelection(itemId: String) {
        selectionManager.toggle(itemId)
        if selectionManager.isEmpty {
            isSelectionModeActive = false
        }
    }

    func beginSelectionMode(itemId: String) {
        isSelectionModeActive = true
        selectionManager.select(itemId)
    }

    /// Sélectionne explicitement un item — utilisé par le drag-to-select pour
    /// imposer l'état "sélectionné" sans toggler (mimick iOS Photos où la
    /// direction du drag détermine select vs deselect, pas toggle).
    func selectItem(id: String) {
        selectionManager.select(id)
    }

    /// Désélectionne explicitement un item — pendant du `selectItem(id:)` pour
    /// le drag-to-select dans le sens "désélection". Si la sélection devient vide,
    /// on sort du mode sélection (cohérence avec `toggleSelection`).
    func deselectItem(id: String) {
        selectionManager.deselect(id)
        if selectionManager.isEmpty {
            isSelectionModeActive = false
        }
    }

    /// Indique si un item est actuellement sélectionné — exposé pour permettre
    /// au drag-to-select de déterminer son mode (sélection vs désélection) à
    /// partir de l'état initial de la première tile rencontrée.
    func isSelected(id: String) -> Bool {
        selectionManager.isSelected(id)
    }

    /// Remplace l'ensemble de la sélection — utilisé par le drag-to-select pour
    /// pousser à chaque frame la nouvelle plage calculée (`initial ∪ range`).
    /// Sort du mode sélection si la nouvelle sélection est vide.
    func setSelection(ids: Set<String>) {
        selectionManager.setAll(ids)
        if selectionManager.isEmpty {
            isSelectionModeActive = false
        }
    }

    func clearSelection() {
        selectionManager.clear()
        isSelectionModeActive = false
    }

    /// Photos cloud correspondant à la sélection courante.
    /// Deux formats d'`id` cohabitent dans la timeline (cf. `GalleryComposer`) :
    /// - item synced     → `id` = `localIdentifier` du PHAsset ;
    /// - item cloud-only → `id` = `GalleryItem.cloudOnlyID(fileId:)` (préfixé `cloud-`).
    /// On teste les deux pour ne rater aucune photo sélectionnée.
    var selectedPhotos: [PhotoSnapshot] {
        let ids = selectionManager.selectedIds
        let livePairs = LivePhotoPairing(photos: cloudPhotos)
        return cloudPhotos.filter {
            !livePairs.motionFileIds.contains($0.fileId)
                && (
                    ids.contains(GalleryItem.cloudOnlyID(fileId: $0.fileId))
                        || (!$0.localIdentifier.isEmpty && ids.contains($0.localIdentifier))
                )
        }
        .map { livePairs.attachMotion(to: $0) }
    }

    func loadAlbums() async -> [AlbumSnapshot] {
        guard let drive = try? driveManager.selectedDrive() else {
            return (try? albumManager.allAlbums()) ?? []
        }
        try? await albumManager.refreshAlbums(driveId: drive.id)
        return (try? albumManager.allAlbums()) ?? []
    }

    // MARK: - Batch Operations

    func deleteSelected() async {
        guard !selectionManager.isEmpty else { return }
        guard let drive = try? driveManager.selectedDrive() else { return }

        // La sélection mixte (cloud + cloudOnly + asset local) est filtrée :
        // seuls les items avec un `fileId` côté kDrive sont enqueuables. Un
        // PHAsset local sans cloud n'a rien à supprimer côté serveur — Phase 2
        // pourra étendre pour supprimer aussi côté PhotoKit.
        // `selectedPhotos` gère le double cas fileId / localIdentifier.
        var fileIdToLocalId: [String: String] = [:]
        for photo in selectedPhotos {
            fileIdToLocalId[photo.fileId] = photo.localIdentifier
            if let motionId = photo.liveMotionFileId { fileIdToLocalId[motionId] = "" }
        }
        let fileIds = Array(fileIdToLocalId.keys)
        guard !fileIds.isEmpty else {
            clearSelection()
            return
        }

        // 1. Enqueue persistant — chaque fileId entre dans DeletionItem en `.queued`.
        //    Si l'app crash entre ici et la fin du drain, le prochain `load()`
        //    reprendra la suppression depuis là où elle s'était arrêtée.
        let requests = fileIds.map {
            DeletionRequest(fileId: $0, driveId: drive.id, localIdentifier: fileIdToLocalId[$0] ?? "")
        }
        do { try await deletionQueueWriter.enqueueDeletions(requests) } catch { return }

        clearSelection()

        // 2. Refresh local du cache deletionItems + recompose pour afficher
        //    immédiatement les badges "deletion in progress" sur les tiles.
        await refreshDeletionState()

        // 3. Drain de la file — séquentiel, met à jour deletionItems après
        //    chaque transition ; surface les échecs via `lastDeletionFailures`.
        await drainDeletionQueue()
    }

    /// Recharge la file de suppression depuis Realm et reconstruit les sections.
    /// Appelé après chaque mutation de la file pour que la UI reflète l'état
    /// persisté sans attendre la fin du drain.
    ///
    /// `alsoReloadCloud: true` re-pull les `Photo` Realm : indispensable après
    /// un `markDeletionCompleted` qui a purgé un enregistrement, sinon le cache
    /// mémoire conserve la photo supprimée et le composer continue à l'afficher
    /// (soit en cloudOnly, soit "synced" derrière un PHAsset local).
    internal func refreshDeletionState(alsoReloadCloud: Bool = false) async {
        if alsoReloadCloud {
            cloudPhotos = (try? currentLibraryPhotos()) ?? []
        }
        deletionItems = Self.indexDeletionsByFileId((try? deletionQueue.allDeletions()) ?? [])
        if case .ready(let summary, _) = state {
            rebuildState(summary: summary)
        }
    }

    /// Notification de fin de drain — pilote le toast récapitulatif côté UI.
    /// Reset à `nil` après que l'UI a consommé l'event (équivalent du
    /// `clearDeletionFailures` côté échecs).
    struct DeletionSummary: Equatable {
        public let completed: Int
        public let failed: Int
    }

    /// Lance un drain de la file de suppression. Idempotent — si un drain est
    /// déjà en cours côté engine, le second retombe en no-op. Pour chaque
    /// transition on relit `cloudPhotos` ET `deletionItems` : le composer voit
    /// disparaître la photo dès que l'engine a confirmé la suppression côté
    /// kDrive (et purgé le Photo Realm dans la même transaction).
    internal func drainDeletionQueue() async {
        let result = await deletionEngine.drain { [weak self] _ in
            // Re-pull du cache après chaque transition. Le callback est marqué
            // `@MainActor` côté engine donc on est déjà sur le main thread —
            // pas de Task imbriquée, on appelle directement la closure async
            // pour garantir que la mise à jour est terminée avant que l'engine
            // ne reprenne. Sans ça, on courait après le drain : N progress
            // ticks → N Task fire-and-forget qui finissent dans le désordre,
            // et la photo restait visible jusqu'au prochain `load()`.
            guard let self else { return }
            await refreshDeletionState(alsoReloadCloud: true)
        }
        // Sécurité ceinture+bretelles : un dernier refresh complet après la
        // sortie du loop (au cas où le dernier `onProgress` aurait été coupé).
        await refreshDeletionState(alsoReloadCloud: true)

        // Toast récapitulatif. On ne publie que si quelque chose s'est passé
        // (drain à vide = no-op, pas de toast intempestif au démarrage).
        if result.completed > 0 || result.failedPermanently > 0 {
            lastDeletionSummary = DeletionSummary(
                completed: result.completed,
                failed: result.failedPermanently
            )
        }

        // Liste détaillée des échecs permanents pour le toast tappable +
        // les badges rouges sur les tiles concernées.
        if result.failedPermanently > 0 {
            let failed = (try? deletionQueue.allDeletions())?
                .filter { $0.state == .failedPermanent }
                .map { DeletionFailure(fileId: $0.fileId, reason: $0.lastErrorReason) } ?? []
            lastDeletionFailures = failed
        } else {
            lastDeletionFailures = []
        }
    }

    /// Reset le summary après que l'UI a affiché son toast — évite ré-émission
    /// au prochain rebuild d'état.
    func clearDeletionSummary() {
        lastDeletionSummary = nil
    }

    /// Re-enqueue forcée d'un item `.failedPermanent` — action "Réessayer"
    /// depuis la sheet d'erreur. Le drain est relancé pour traiter le retry
    /// tout de suite.
    func retryDeletion(fileId: String) async {
        try? await deletionQueueWriter.requeueDeletion(fileId: fileId)
        await refreshDeletionState()
        await drainDeletionQueue()
    }

    /// Annule définitivement une suppression en échec permanent (purge du
    /// DeletionItem). Le `Photo` reste intact côté kDrive ET côté Realm —
    /// l'utilisateur revoit la photo dans sa galerie normalement.
    func cancelDeletion(fileId: String) async {
        // `markDeletionFailedPermanent` n'est pas annulable via `cancelDeletion`
        // (qui est limité à `.queued`). Pour les permanents, on les passe par
        // `requeueDeletion` (état .queued) puis `cancelDeletion` qui purge.
        // Plus simple : on écrit directement une purge dédiée. Phase 2 — pour
        // l'instant on requeue + cancel en deux temps, simple à comprendre.
        try? await deletionQueueWriter.requeueDeletion(fileId: fileId)
        try? await deletionQueueWriter.cancelDeletion(fileId: fileId)
        await refreshDeletionState()
    }

    /// Reset la liste d'échecs après que l'UI ait affiché son toast — évite que
    /// le toast réapparaisse au prochain rebuild d'état.
    func clearDeletionFailures() {
        lastDeletionFailures = []
    }

    /// Télécharge les photos sélectionnées et les importe dans la Photothèque iOS.
    /// - Returns: nombre de fichiers effectivement importés.
    /// - Throws: `MediaDownloadError` (permission refusée, erreur serveur…) propagé
    ///   directement à l'appelant pour qu'il puisse afficher un message précis.
    func downloadSelected() async throws -> Int {
        guard !selectionManager.isEmpty else { return 0 }
        guard let drive = try? driveManager.selectedDrive() else { return 0 }

        let count = try await downloader.downloadAndImport(photos: selectedPhotos, driveId: drive.id)
        clearSelection()
        return count
    }

    func addSelectedToAlbum(albumId: String) async {
        guard !selectionManager.isEmpty else { return }
        guard let drive = try? driveManager.selectedDrive() else { return }

        // 1 seul appel API pour N photos grâce au bulk natif kDrive (cf. AlbumManager).
        // On extrait les fileIds depuis selectedPhotos (gère le cas synced / cloud-only).
        let fileIds = selectedPhotos.flatMap { [$0.fileId, $0.liveMotionFileId].compactMap { $0 } }
        try? await albumManager.addPhotos(fileIds: fileIds, toAlbumId: albumId, driveId: drive.id)
    }
}
