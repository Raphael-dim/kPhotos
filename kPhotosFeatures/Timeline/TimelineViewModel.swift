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

import Combine
import Foundation
import kPhotosCore

@MainActor
public final class TimelineViewModel: ObservableObject {
    public enum State: Equatable {
        case loading
        case permissionNeeded
        case permissionDenied
        case noDriveSelected
        case ready(summary: PhotoLibrarySummary, sections: [GallerySection])
        case error(message: String)
    }

    public enum SyncState: Equatable {
        case idle
        case running(progress: SyncProgress)
        case finished(progress: SyncProgress)
        case failed(message: String)
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var syncState: SyncState = .idle
    @Published public private(set) var selectionManager = SelectionManager()
    @Published public var isSelectionModeActive = false

    /// Limite par session de sync — laisse une marge raisonnable face au rate limit (60 req/min).
    public var maxAssetsPerSync = 25

    /// Nom du dossier racine — lu depuis les réglages (paramétrable), retombe sur
    /// la valeur par défaut si Realm est indisponible.
    private var rootFolderName: String {
        (try? syncSettings.current().rootFolderName) ?? SyncSettingsSnapshot.defaultRootFolderName
    }

    @InjectService private var photos: PhotoReading
    @InjectService private var assetReader: PHAssetReading
    @InjectService private var driveManager: DriveManaging
    @InjectService private var sync: PhotoSyncing
    @InjectService private var composer: GalleryComposing
    @InjectService private var uploadQueue: UploadQueueReading
    @InjectService private var backupQueue: BackupQueueReading
    @InjectService private var backupQueueWriter: BackupQueueWriting
    @InjectService private var deletionQueue: DeletionQueueReading
    @InjectService private var deletionQueueWriter: DeletionQueueWriting
    @InjectService private var deletionEngine: PhotoDeleting
    @InjectService private var photoLibraryObserver: PhotoLibraryObserving
    @InjectService private var syncSettings: SyncSettingsReading
    @InjectService private var api: PhotoApiFetching
    @InjectService private var photoWriter: PhotoWriting
    @InjectService private var albumManager: AlbumManaging
    @InjectService private var downloader: MediaDownloading

    private var cancellables: Set<AnyCancellable> = []

    // Sources fusionnées en mémoire — gardées pour reconstruire les sections quand
    // une seule des trois change (ex: upload state qui transite sans toucher Realm).
    private var localAssets: [LocalAssetSnapshot] = []
    private var cloudPhotos: [PhotoSnapshot] = []
    /// Cache de la file persistante : `localIdentifier → snapshot`. Rechargé à
    /// chaque `load()` et après chaque `runSync()`. Phase 2 : observation
    /// Realm-native pour mise à jour réactive sans rebuild explicit.
    private var backupItems: [String: BackupItemSnapshot] = [:]
    /// Cache de la file de suppression : `fileId → snapshot`. Rechargé après
    /// chaque enqueue/drain. Pilote les badges "deletion in progress" dans la
    /// galerie via le composer.
    private var deletionItems: [String: DeletionItemSnapshot] = [:]
    public struct DeletionFailure: Equatable, Identifiable {
        public let fileId: String
        public let reason: String
        public var id: String { fileId }
    }
    /// Liste des items dont la suppression a échoué définitivement lors du
    /// dernier drain — utilisée par l'UI pour afficher un toast récapitulatif.
    /// Reset à chaque nouveau drain.
    @Published public private(set) var lastDeletionFailures: [DeletionFailure] = []

    /// Empêche les refresh distants concurrents (open + pull-to-refresh quasi simultanés).
    private var isRefreshingCloud = false

    public init() {
        bindToUploadQueue()
    }

    public func load() async {
        let auth = assetReader.currentAuthorization()
        switch auth {
        case .notDetermined:
            state = .permissionNeeded
            return
        case .denied, .restricted:
            state = .permissionDenied
            return
        case .authorized, .limited:
            // Démarre l'observation PhotoKit dès qu'on a l'autorisation. Idempotent
            // — appel à chaque `load()` sans effet après le premier (singleton DI).
            // Une nouvelle photo prise depuis l'appareil sera automatiquement
            // enqueued dans `BackupItem` via `photoLibraryDidChange`.
            photoLibraryObserver.startObserving()
        }

        // `try?` aplatit `throws -> DriveSnapshot?` en `DriveSnapshot?` (throw et nil
        // sont indistinguables ici — les deux signifient "pas de drive utilisable").
        guard (try? driveManager.selectedDrive()) != nil else {
            state = .noDriveSelected
            return
        }

        // 1. PhotoKit en premier — instantané, c'est ce qui fait que la galerie
        //    apparaît "déjà disponible" à l'ouverture.
        localAssets = await assetReader.fetchAssetSnapshots(filter: .both)
        // 2. Realm — éventuellement vide au premier lancement.
        cloudPhotos = (try? photos.allPhotos()) ?? []
        backupItems = Self.indexByLocalId((try? backupQueue.allItems()) ?? [])
        deletionItems = Self.indexDeletionsByFileId((try? deletionQueue.allDeletions()) ?? [])

        let summary = await assetReader.summary()
        rebuildState(summary: summary)

        // 3a. Réconcilie la file persistante avec la photothèque iOS — enqueue
        //    en arrière-plan les assets locaux qui ne sont ni synced cloud ni
        //    déjà connus de la file. Idempotent, sûr à lancer à chaque load().
        //    Une fois fini, on relit la file pour rafraîchir les badges.
        Task { await reconcileBackupQueue() }

        // 3b. Refresh distant en tâche de fond : on récupère les fichiers ajoutés
        //    depuis un autre appareil (web, autre tel, etc.) sans bloquer l'UI.
        //    Le cache local s'affiche immédiatement, puis les nouveaux fichiers
        //    apparaissent quand le listing kDrive revient.
        Task { await refreshCloud() }

        // 3c. Drain de la file de suppression — reprend après un crash ou un
        //     redémarrage de l'app si des deletes étaient en cours. Idempotent,
        //     no-op quand la file est vide.
        Task { await drainDeletionQueue() }
    }

    /// Pousse la file persistante : appelle `sync.reconcile()` puis relit
    /// `backupItems` pour rafraîchir l'UI. Erreurs silencieuses — le pire cas
    /// est "la file reste dans son état précédent", la galerie continue de
    /// fonctionner.
    private func reconcileBackupQueue() async {
        try? await sync.reconcile()
        backupItems = Self.indexByLocalId((try? backupQueue.allItems()) ?? [])
        if case .ready(let summary, _) = state {
            rebuildState(summary: summary)
        }
    }

    /// Pull du listing kDrive → upsert dans Realm → rafraîchit l'état.
    /// Idempotent et silencieux côté erreurs (réseau, serveur) : on garde le cache
    /// local affiché. Utilisé par `load()` (background), `runSync()` (pull-then-push)
    /// et le pull-to-refresh de la `TimelineView`.
    public func refreshCloud() async {
        guard !isRefreshingCloud else { return }
        isRefreshingCloud = true
        defer { isRefreshingCloud = false }

        guard let drive = try? driveManager.selectedDrive() else { return }
        do {
            let rootFolderId = try await driveManager.ensureRootFolder(folderName: rootFolderName)
            try await sync.refreshFolder(driveId: drive.id, folderId: rootFolderId)
            cloudPhotos = (try? photos.allPhotos()) ?? []
            if case .ready(let summary, _) = state {
                rebuildState(summary: summary)
            }
        } catch {
            // Volontairement silencieux : la galerie reste utilisable hors-ligne.
        }
    }

    /// Liste ordonnée des médias visibles dans la galerie, prête à être passée au
    /// viewer plein écran. Suit l'ordre que voit l'utilisateur (sections → items)
    /// pour que le swipe corresponde exactement au défilement de la galerie.
    /// Pour un item synchronisé, on privilégie la source cloud (preview HD déjà
    /// disponible côté kDrive, meilleure qualité que la vignette PhotoKit).
    public var orderedViewerMedia: [ViewerMedia] {
        guard case .ready(_, let sections) = state else { return [] }
        return sections.flatMap { $0.items }.compactMap(viewerMedia(for:))
    }

    /// Convertit un `GalleryItem` en `ViewerMedia` ouvrable. Précédence : cloud
    /// avant local — le preview HD kDrive est généralement plus pratique que la
    /// requête `PHImageManager` (déjà en cache après la sync). Retourne nil si
    /// l'item ne pointe vers aucune source résolvable (cas improbable).
    public func viewerMedia(for item: GalleryItem) -> ViewerMedia? {
        if let fileId = item.cloudFileId,
           let snapshot = cloudPhotos.first(where: { $0.fileId == fileId }) {
            return .cloud(snapshot)
        }
        if let localId = item.localAssetIdentifier,
           let asset = localAssets.first(where: { $0.localIdentifier == localId }) {
            return .local(asset)
        }
        return nil
    }

    public func requestPhotoLibraryAccess() async {
        _ = await assetReader.requestAuthorization()
        await load()
    }

    /// Nombre d'items actuellement en `.failedPermanent`. Utilisé par le toolbar
    /// pour afficher un badge "Tout réessayer (N)" quand non-zéro.
    public var failedItemCount: Int {
        backupItems.values.filter { $0.state == .failedPermanent }.count
    }

    /// Re-enqueue un item `.failedPermanent` ou `.skipped` (action "Réessayer
    /// cette photo" dans la sheet de détail). Le `clientToken` est conservé →
    /// upload idempotent côté kDrive (pas de doublon si le précédent essai
    /// avait en fait réussi avant de perdre la réponse).
    public func retryItem(localIdentifier: String) async {
        try? await backupQueueWriter.requeue(localIdentifier: localIdentifier)
        await reconcileBackupQueue()
    }

    /// Marque définitivement un item comme `.skipped` (action "Ignorer cette
    /// photo"). N'apparaîtra plus dans la file ; visuellement le badge orange
    /// disparaît et la photo retombe en gris (Phase 2c différenciera visuellement).
    public func skipItem(localIdentifier: String) async {
        try? await backupQueueWriter.markSkipped(
            localIdentifier: localIdentifier,
            reason: "Ignoré par l'utilisateur."
        )
        await reconcileBackupQueue()
    }

    /// Re-enqueue en masse de tous les items `.failedPermanent` (action toolbar
    /// "Tout réessayer"). Retourne le nombre d'items reprogrammés pour feedback
    /// toast.
    @discardableResult
    public func retryAllFailed() async -> Int {
        let count = (try? await backupQueueWriter.requeueAllPermanentlyFailed()) ?? 0
        await reconcileBackupQueue()
        return count
    }

    public func runSync() async {
        guard let drive = try? driveManager.selectedDrive() else {
            syncState = .failed(message: "Aucun kDrive sélectionné.")
            return
        }
        syncState = .running(progress: SyncProgress(completed: 0, total: 0, lastUploadedFileName: nil))
        do {
            // L'espace Private est découvert automatiquement, puis kPhotos/ est créé dedans.
            // Cf. AGENTS.md §8 (arborescence kDrive).
            let rootFolderId = try await driveManager.ensureRootFolder(folderName: rootFolderName)
            // Pull-then-push : on commence par récupérer les fichiers ajoutés depuis
            // un autre appareil (web, autre tel) avant d'envoyer ceux qu'on a localement.
            // Erreur ici = on continue quand même avec le push pour ne pas pénaliser
            // l'utilisateur en cas de timeout sur le listing.
            try? await sync.refreshFolder(driveId: drive.id, folderId: rootFolderId)
            // Manuel = drainer TOUTE la file (pas de cap arbitraire). C'est la
            // sémantique "comme Google Photos" : un clic sauvegarde tout ce qui
            // reste. `performWithRetry` côté API gère 429/5xx avec backoff donc
            // on ne sature pas malgré la séquence longue. `BackgroundSyncScheduler`
            // garde son budget par session via `maxAssetsPerSync` côté BG.
            try await sync.runFullSync(
                driveId: drive.id,
                folderId: rootFolderId,
                maxItems: nil,
                onProgress: { [weak self] progress in
                    self?.syncState = .running(progress: progress)
                }
            )
            if case .running(let progress) = syncState {
                syncState = .finished(progress: progress)
            }
            await load()
        } catch {
            syncState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Reactive bindings

    /// L'upload queue émet à chaque transition (pending → uploading → completed).
    /// On rebuild les sections via le composer (pur) sans retoucher PhotoKit/Realm.
    private func bindToUploadQueue() {
        uploadQueue.statesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard case .ready(let summary, _) = self.state else { return }
                self.rebuildState(summary: summary)
            }
            .store(in: &cancellables)
    }

    /// Recompose les sections à partir des trois sources en mémoire. Pure (composer).
    /// Le filtre photo/vidéo des réglages s'applique uniquement à la sync, pas à
    /// l'affichage : la galerie reste exhaustive pour rester un index fidèle de
    /// la photothèque locale.
    private func rebuildState(summary: PhotoLibrarySummary) {
        let sections = composer.compose(
            localAssets: localAssets,
            cloudPhotos: cloudPhotos,
            backupItems: backupItems,
            deletionItems: deletionItems,
            uploadStates: uploadQueue.currentStates,
            calendar: .iso8601
        )
        state = .ready(summary: summary, sections: sections)
    }

    /// Indexe `[BackupItemSnapshot]` par `localIdentifier` pour les lookups O(1)
    /// du composer.
    private static func indexByLocalId(_ items: [BackupItemSnapshot]) -> [String: BackupItemSnapshot] {
        var dict: [String: BackupItemSnapshot] = [:]
        dict.reserveCapacity(items.count)
        for item in items { dict[item.localIdentifier] = item }
        return dict
    }

    /// Indexe `[DeletionItemSnapshot]` par `fileId` (clé primaire kDrive).
    private static func indexDeletionsByFileId(_ items: [DeletionItemSnapshot]) -> [String: DeletionItemSnapshot] {
        var dict: [String: DeletionItemSnapshot] = [:]
        dict.reserveCapacity(items.count)
        for item in items { dict[item.fileId] = item }
        return dict
    }

    // MARK: - Selection Management

    public func toggleSelection(itemId: String) {
        selectionManager.toggle(itemId)
        if selectionManager.isEmpty {
            isSelectionModeActive = false
        }
    }

    public func beginSelectionMode(itemId: String) {
        isSelectionModeActive = true
        selectionManager.select(itemId)
    }

    /// Sélectionne explicitement un item — utilisé par le drag-to-select pour
    /// imposer l'état "sélectionné" sans toggler (mimick iOS Photos où la
    /// direction du drag détermine select vs deselect, pas toggle).
    public func selectItem(id: String) {
        selectionManager.select(id)
    }

    /// Désélectionne explicitement un item — pendant du `selectItem(id:)` pour
    /// le drag-to-select dans le sens "désélection". Si la sélection devient vide,
    /// on sort du mode sélection (cohérence avec `toggleSelection`).
    public func deselectItem(id: String) {
        selectionManager.deselect(id)
        if selectionManager.isEmpty {
            isSelectionModeActive = false
        }
    }

    /// Indique si un item est actuellement sélectionné — exposé pour permettre
    /// au drag-to-select de déterminer son mode (sélection vs désélection) à
    /// partir de l'état initial de la première tile rencontrée.
    public func isSelected(id: String) -> Bool {
        selectionManager.isSelected(id)
    }

    /// Remplace l'ensemble de la sélection — utilisé par le drag-to-select pour
    /// pousser à chaque frame la nouvelle plage calculée (`initial ∪ range`).
    /// Sort du mode sélection si la nouvelle sélection est vide.
    public func setSelection(ids: Set<String>) {
        selectionManager.setAll(ids)
        if selectionManager.isEmpty {
            isSelectionModeActive = false
        }
    }

    public func clearSelection() {
        selectionManager.clear()
        isSelectionModeActive = false
    }

    /// Photos cloud correspondant à la sélection courante.
    /// Deux formats d'`id` cohabitent dans la timeline (cf. `GalleryComposer`) :
    /// - item synced     → `id` = `localIdentifier` du PHAsset ;
    /// - item cloud-only → `id` = `GalleryItem.cloudOnlyID(fileId:)` (préfixé `cloud-`).
    /// On teste les deux pour ne rater aucune photo sélectionnée.
    public var selectedPhotos: [PhotoSnapshot] {
        let ids = selectionManager.selectedIds
        return cloudPhotos.filter {
            ids.contains(GalleryItem.cloudOnlyID(fileId: $0.fileId)) ||
            (!$0.localIdentifier.isEmpty && ids.contains($0.localIdentifier))
        }
    }

    public func loadAlbums() async -> [AlbumSnapshot] {
        guard let drive = try? driveManager.selectedDrive() else {
            return (try? albumManager.allAlbums()) ?? []
        }
        try? await albumManager.refreshAlbums(driveId: drive.id)
        return (try? albumManager.allAlbums()) ?? []
    }

    // MARK: - Batch Operations

    public func deleteSelected() async {
        guard !selectionManager.isEmpty else { return }
        guard let drive = try? driveManager.selectedDrive() else { return }

        // La sélection mixte (cloud + cloudOnly + asset local) est filtrée :
        // seuls les items avec un `fileId` côté kDrive sont enqueuables. Un
        // PHAsset local sans cloud n'a rien à supprimer côté serveur — Phase 2
        // pourra étendre pour supprimer aussi côté PhotoKit.
        // `selectedPhotos` gère le double cas fileId / localIdentifier.
        let fileIdToLocalId = Dictionary(
            uniqueKeysWithValues: selectedPhotos.map { ($0.fileId, $0.localIdentifier) }
        )
        let fileIds = Array(fileIdToLocalId.keys)
        guard !fileIds.isEmpty else {
            clearSelection()
            return
        }

        // 1. Enqueue persistant — chaque fileId entre dans DeletionItem en `.queued`.
        //    Si l'app crash entre ici et la fin du drain, le prochain `load()`
        //    reprendra la suppression depuis là où elle s'était arrêtée.
        for fileId in fileIds {
            try? await deletionQueueWriter.enqueueDeletion(
                fileId: fileId,
                driveId: drive.id,
                localIdentifier: fileIdToLocalId[fileId] ?? ""
            )
        }

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
    private func refreshDeletionState(alsoReloadCloud: Bool = false) async {
        if alsoReloadCloud {
            cloudPhotos = (try? photos.allPhotos()) ?? []
        }
        deletionItems = Self.indexDeletionsByFileId((try? deletionQueue.allDeletions()) ?? [])
        if case .ready(let summary, _) = state {
            rebuildState(summary: summary)
        }
    }

    /// Notification de fin de drain — pilote le toast récapitulatif côté UI.
    /// Reset à `nil` après que l'UI a consommé l'event (équivalent du
    /// `clearDeletionFailures` côté échecs).
    public struct DeletionSummary: Equatable {
        public let completed: Int
        public let failed: Int
    }
    @Published public private(set) var lastDeletionSummary: DeletionSummary?

    /// Lance un drain de la file de suppression. Idempotent — si un drain est
    /// déjà en cours côté engine, le second retombe en no-op. Pour chaque
    /// transition on relit `cloudPhotos` ET `deletionItems` : le composer voit
    /// disparaître la photo dès que l'engine a confirmé la suppression côté
    /// kDrive (et purgé le Photo Realm dans la même transaction).
    private func drainDeletionQueue() async {
        let result = await deletionEngine.drain { [weak self] _ in
            // Re-pull du cache après chaque transition. Le callback est marqué
            // `@MainActor` côté engine donc on est déjà sur le main thread —
            // pas de Task imbriquée, on appelle directement la closure async
            // pour garantir que la mise à jour est terminée avant que l'engine
            // ne reprenne. Sans ça, on courait après le drain : N progress
            // ticks → N Task fire-and-forget qui finissent dans le désordre,
            // et la photo restait visible jusqu'au prochain `load()`.
            guard let self else { return }
            await self.refreshDeletionState(alsoReloadCloud: true)
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
    public func clearDeletionSummary() {
        lastDeletionSummary = nil
    }

    /// Re-enqueue forcée d'un item `.failedPermanent` — action "Réessayer"
    /// depuis la sheet d'erreur. Le drain est relancé pour traiter le retry
    /// tout de suite.
    public func retryDeletion(fileId: String) async {
        try? await deletionQueueWriter.requeueDeletion(fileId: fileId)
        await refreshDeletionState()
        await drainDeletionQueue()
    }

    /// Annule définitivement une suppression en échec permanent (purge du
    /// DeletionItem). Le `Photo` reste intact côté kDrive ET côté Realm —
    /// l'utilisateur revoit la photo dans sa galerie normalement.
    public func cancelDeletion(fileId: String) async {
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
    public func clearDeletionFailures() {
        lastDeletionFailures = []
    }

    /// Télécharge les photos sélectionnées et les importe dans la Photothèque iOS.
    /// - Returns: nombre de fichiers effectivement importés.
    /// - Throws: `MediaDownloadError` (permission refusée, erreur serveur…) propagé
    ///   directement à l'appelant pour qu'il puisse afficher un message précis.
    public func downloadSelected() async throws -> Int {
        guard !selectionManager.isEmpty else { return 0 }
        guard let drive = try? driveManager.selectedDrive() else { return 0 }

        let count = try await downloader.downloadAndImport(photos: selectedPhotos, driveId: drive.id)
        clearSelection()
        return count
    }

    public func addSelectedToAlbum(albumId: String) async {
        guard !selectionManager.isEmpty else { return }
        guard let drive = try? driveManager.selectedDrive() else { return }

        // 1 seul appel API pour N photos grâce au bulk natif kDrive (cf. AlbumManager).
        // On extrait les fileIds depuis selectedPhotos (gère le cas synced / cloud-only).
        let fileIds = selectedPhotos.map { $0.fileId }
        try? await albumManager.addPhotos(fileIds: fileIds, toAlbumId: albumId, driveId: drive.id)
    }
}
