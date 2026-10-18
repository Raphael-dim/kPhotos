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
import kPhotosResources

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

    @Published internal(set) var backupOverview = BackupOverview()
    var backupInventoryGeneration = UUID()
    var hasReconciledBackup = false
    var backupReadError: String?
    var localReloadTask: Task<Void, Never>?

    @Published public internal(set) var state: State = .loading
    @Published public internal(set) var syncState: SyncState = .idle
    @Published public internal(set) var selectionManager = SelectionManager()
    @Published public var isSelectionModeActive = false

    /// Limite par session de sync — laisse une marge raisonnable face au rate limit (60 req/min).
    public var maxAssetsPerSync = 25

    /// Nom du dossier racine — lu depuis les réglages (paramétrable), retombe sur
    /// la valeur par défaut si Realm est indisponible.
    private var rootFolderName: String {
        (try? syncSettings.current().rootFolderName) ?? SyncSettingsSnapshot.defaultRootFolderName
    }

    @InjectService private var preparedIndex: PreparedMediaIndexSyncing
    @InjectService private var metadataIndexer: EmbeddedMetadataIndexing
    @InjectService var photos: PhotoReading
    @InjectService var assetReader: PHAssetReading
    @InjectService var driveManager: DriveManaging
    @InjectService var sync: PhotoSyncing
    @InjectService private var composer: GalleryComposing
    @InjectService var uploadQueue: UploadQueueReading
    @InjectService var backupQueue: BackupQueueReading
    @InjectService var backupQueueWriter: BackupQueueWriting
    @InjectService var deletionQueue: DeletionQueueReading
    @InjectService var deletionQueueWriter: DeletionQueueWriting
    @InjectService var deletionEngine: PhotoDeleting
    @InjectService var photoLibraryObserver: PhotoLibraryObserving
    @InjectService var syncSettings: SyncSettingsReading
    @InjectService var albumManager: AlbumManaging
    @InjectService var downloader: MediaDownloading

    var cancellables: Set<AnyCancellable> = []

    // Sources fusionnées en mémoire — gardées pour reconstruire les sections quand
    // une seule des trois change (ex: upload state qui transite sans toucher Realm).
    var localAssets: [LocalAssetSnapshot] = []
    var cloudPhotos: [PhotoSnapshot] = []
    /// Cache de la file persistante : `localIdentifier → snapshot`. Rechargé à
    /// chaque `load()` et après chaque `runSync()`. Phase 2 : observation
    /// Realm-native pour mise à jour réactive sans rebuild explicit.
    var backupItems: [String: BackupItemSnapshot] = [:]
    /// Cache de la file de suppression : `fileId → snapshot`. Rechargé après
    /// chaque enqueue/drain. Pilote les badges "deletion in progress" dans la
    /// galerie via le composer.
    var deletionItems: [String: DeletionItemSnapshot] = [:]
    public struct DeletionFailure: Equatable, Identifiable {
        public let fileId: String
        public let reason: String
        public var id: String { fileId }
    }

    /// Liste des items dont la suppression a échoué définitivement lors du
    /// dernier drain — utilisée par l'UI pour afficher un toast récapitulatif.
    /// Reset à chaque nouveau drain.
    @Published internal(set) var lastDeletionSummary: DeletionSummary?

    @Published public internal(set) var lastDeletionFailures: [DeletionFailure] = []

    /// Empêche les refresh distants concurrents (open + pull-to-refresh quasi simultanés).
    @Published public private(set) var cloudRefreshError: String?
    @Published public private(set) var isRefreshingCloud = false
    public var cloudPhotoCount: Int { cloudPhotos.count }

    public init() {
        bindToUploadQueue()
        bindToLibrarySettings()
        bindToBackupStatus()
        photos.changesPublisher
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, case .ready(let summary, _) = state else { return }
                self.cloudPhotos = (try? currentLibraryPhotos()) ?? []
                rebuildState(summary: summary)
            }
            .store(in: &cancellables)
    }

    public func load() async {
        backupInventoryGeneration = UUID()
        hasReconciledBackup = false
        updateBackupOverview()
        let auth = assetReader.currentAuthorization()
        let hasLocalAccess = auth == .authorized || auth == .limited
        if hasLocalAccess { photoLibraryObserver.startObserving() }

        // `try?` aplatit `throws -> DriveSnapshot?` en `DriveSnapshot?` (throw et nil
        // sont indistinguables ici — les deux signifient "pas de drive utilisable").
        guard (try? driveManager.selectedDrive()) != nil else {
            state = .noDriveSelected
            return
        }

        // 1. PhotoKit en premier — instantané, c'est ce qui fait que la galerie
        //    apparaît "déjà disponible" à l'ouverture.
        localAssets = hasLocalAccess ? await assetReader.fetchAssetSnapshots(filter: .both) : []
        // 2. Realm — éventuellement vide au premier lancement.
        cloudPhotos = (try? currentLibraryPhotos()) ?? []
        backupItems = Self.indexByLocalId((try? backupQueue.allItems()) ?? [])
        deletionItems = Self.indexDeletionsByFileId((try? deletionQueue.allDeletions()) ?? [])

        let summary = hasLocalAccess ? await assetReader.summary() : .empty
        rebuildState(summary: summary)
        // Automatic preparation is independent of rendering the cached gallery.

        // 3a. Réconcilie la file persistante avec la photothèque iOS — enqueue
        //    en arrière-plan les assets locaux qui ne sont ni synced cloud ni
        //    déjà connus de la file. Idempotent, sûr à lancer à chaque load().
        //    Une fois fini, on relit la file pour rafraîchir les badges.
        if hasLocalAccess { Task { await reconcileBackupQueue() } }

        // 3b. Refresh distant en tâche de fond : on récupère les fichiers ajoutés
        //    depuis un autre appareil (web, autre tel, etc.) sans bloquer l'UI.
        //    Le cache local s'affiche immédiatement, puis les nouveaux fichiers
        //    apparaissent quand le listing kDrive revient.
        Task {
            guard let drive = try? driveManager.selectedDrive(), !drive.rootFolderId.isEmpty else { return }
            do { try await preparedIndex.refresh(driveId: drive.id, rootId: drive.rootFolderId) } catch {
            /* Existing gallery remains available; the prepared cache can be retried. */ }
            cloudPhotos = (try? currentLibraryPhotos()) ?? []
            if case .ready(let summary, _) = state { rebuildState(summary: summary) }
            if LibraryRefreshSchedule().shouldRefresh(
                driveId: drive.id,
                rootId: drive.rootFolderId,
                hasCache: !cloudPhotos.isEmpty
            ) {
                await refreshCloud()
            } else {
                await metadataIndexer.start(driveId: drive.id, rootId: drive.rootFolderId)
            }
        }

        // 3c. Drain de la file de suppression — reprend après un crash ou un
        //     redémarrage de l'app si des deletes étaient en cours. Idempotent,
        //     no-op quand la file est vide.
        Task { await drainDeletionQueue() }
    }

    /// Pousse la file persistante : appelle `sync.reconcile()` puis relit
    /// `backupItems` pour rafraîchir l'UI. Erreurs silencieuses — le pire cas
    /// est "la file reste dans son état précédent", la galerie continue de
    /// fonctionner.
    public func refreshCloud() async {
        guard !isRefreshingCloud else { return }
        isRefreshingCloud = true
        defer { isRefreshingCloud = false }

        do {
            cloudPhotos = try await CloudLibraryRefresh(
                drives: driveManager, settings: syncSettings, sync: sync, photos: photos
            ).load()
            if let drive = try driveManager.selectedDrive(), !drive.rootFolderId.isEmpty {
                do { try await preparedIndex.refresh(driveId: drive.id, rootId: drive.rootFolderId, force: true) } catch {
                /* Listing remains valid; the optional prepared index can be retried independently. */ }
                await metadataIndexer.start(driveId: drive.id, rootId: drive.rootFolderId)
            }
            cloudRefreshError = nil
            if case .ready(let summary, _) = state {
                rebuildState(summary: summary)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            cloudRefreshError = error.localizedDescription
        }
    }

    func bindToLibrarySettings() {
        syncSettings.publisher
            .receive(on: DispatchQueue.main)
            .map { [weak self] snapshot in
                let drive = try? self?.driveManager.selectedDrive()
                return [snapshot.rootFolderName, String(drive?.id ?? 0), drive?.rootFolderId ?? ""]
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                backupInventoryGeneration = UUID()
                hasReconciledBackup = false
                cloudPhotos = (try? currentLibraryPhotos()) ?? []
                cloudRefreshError = nil
                if case .ready(let summary, _) = state { rebuildState(summary: summary) }
                Task {
                    await self.metadataIndexer.suspend()
                    await self.refreshCloud()
                    await self.reconcileBackupQueue()
                }
            }
            .store(in: &cancellables)
    }

    /// Liste ordonnée des médias visibles dans la galerie, prête à être passée au
    /// viewer plein écran. Suit l'ordre que voit l'utilisateur (sections → items)
    /// pour que le swipe corresponde exactement au défilement de la galerie.
    /// Pour un item synchronisé, on privilégie la source cloud (preview HD déjà
    /// disponible côté kDrive, meilleure qualité que la vignette PhotoKit).
    public var orderedViewerMedia: [ViewerMedia] {
        guard case .ready(_, let sections) = state else { return [] }
        // Resolve the full pager in linear time; repeated array searches freeze large libraries on tap.
        let cloudById = Dictionary(cloudPhotos.map { ($0.fileId, $0) }, uniquingKeysWith: { _, last in last })
        let livePairs = LivePhotoPairing(photos: cloudPhotos)
        let localById = Dictionary(localAssets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { _, last in last })
        return sections.flatMap(\.items).compactMap { item in
            if let fileId = item.cloudFileId, let photo = cloudById[fileId] {
                return .cloud(livePairs.attachMotion(to: photo))
            }
            if let localId = item.localAssetIdentifier, let asset = localById[localId] { return .local(asset) }
            return nil
        }
    }

    /// Convertit un `GalleryItem` en `ViewerMedia` ouvrable. Précédence : cloud
    /// avant local — le preview HD kDrive est généralement plus pratique que la
    /// requête `PHImageManager` (déjà en cache après la sync). Retourne nil si
    /// l'item ne pointe vers aucune source résolvable (cas improbable).
    func currentLibraryPhotos() throws -> [PhotoSnapshot] {
        guard let drive = try driveManager.selectedDrive(), !drive.rootFolderId.isEmpty else { return [] }
        return try photos.allPhotos().filter {
            $0.driveId == drive.id && $0.libraryRootId == drive.rootFolderId && $0.isAvailable
        }
    }

    public func viewerMedia(for item: GalleryItem) -> ViewerMedia? {
        if let fileId = item.cloudFileId,
           let snapshot = cloudPhotos.first(where: { $0.fileId == fileId }) {
            return .cloud(LivePhotoPairing(photos: cloudPhotos).attachMotion(to: snapshot))
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
        let count = await (try? backupQueueWriter.requeueAllPermanentlyFailed()) ?? 0
        await reconcileBackupQueue()
        return count
    }

    public func runSync() async {
        if case .running = syncState { return }
        guard let drive = try? driveManager.selectedDrive() else {
            syncState = .failed(message: L10n.Timeline.noDriveTitle)
            return
        }
        syncState = .running(progress: SyncProgress(completed: 0, total: 0, lastUploadedFileName: nil))
        updateBackupOverview()
        do {
            // L'espace Private est découvert automatiquement, puis kPhotos/ est créé dedans.
            // Cf. AGENTS.md §8 (arborescence kDrive).
            let rootFolderId = try await driveManager.ensureRootFolder(folderName: rootFolderName)
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
                    self?.updateBackupOverview()
                }
            )
            if case .running(let progress) = syncState {
                syncState = progress.completed == progress.total
                    ? .finished(progress: progress)
                    : .failed(message: L10n.BackupSafety.partial(completed: progress.completed, total: progress.total))
            }
            await load()
        } catch {
            syncState = .failed(message: error.localizedDescription)
            updateBackupOverview()
        }
    }

    // MARK: - Reactive bindings

    /// L'upload queue émet à chaque transition (pending → uploading → completed).
    /// On rebuild les sections via le composer (pur) sans retoucher PhotoKit/Realm.
    func bindToUploadQueue() {
        uploadQueue.statesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard case .ready(let summary, _) = state else { return }
                rebuildState(summary: summary)
            }
            .store(in: &cancellables)
    }

    /// Recompose les sections à partir des trois sources en mémoire. Pure (composer).
    /// Le filtre photo/vidéo des réglages s'applique uniquement à la sync, pas à
    /// l'affichage : la galerie reste exhaustive pour rester un index fidèle de
    /// la photothèque locale.
    func rebuildState(summary: PhotoLibrarySummary) {
        let sections = composer.compose(
            localAssets: localAssets,
            cloudPhotos: cloudPhotos,
            backupItems: backupItems,
            deletionItems: deletionItems,
            uploadStates: uploadQueue.currentStates,
            calendar: .iso8601
        )
        state = .ready(summary: summary, sections: sections)
        updateBackupOverview()
    }

    /// Indexe `[BackupItemSnapshot]` par `localIdentifier` pour les lookups O(1)
    /// du composer.
    static func indexByLocalId(_ items: [BackupItemSnapshot]) -> [String: BackupItemSnapshot] {
        var dict: [String: BackupItemSnapshot] = [:]
        dict.reserveCapacity(items.count)
        for item in items {
            dict[item.localIdentifier] = item
        }
        return dict
    }

    /// Indexe `[DeletionItemSnapshot]` par `fileId` (clé primaire kDrive).
    static func indexDeletionsByFileId(_ items: [DeletionItemSnapshot]) -> [String: DeletionItemSnapshot] {
        var dict: [String: DeletionItemSnapshot] = [:]
        dict.reserveCapacity(items.count)
        for item in items {
            dict[item.fileId] = item
        }
        return dict
    }
}
