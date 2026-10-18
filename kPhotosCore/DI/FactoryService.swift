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

public enum FactoryService {
    public static let store = SimpleResolver.sharedResolver

    /// À appeler une seule fois au démarrage (`kPhotosApp.init`).
    public static func registerAll(authConfig: AuthConfig = .infomaniak) {
        registerInfrastructure()
        registerAuth(config: authConfig)
        registerApiLayer()
        registerManagers()
        registerGallery()
        registerSync()
    }

    private static func registerInfrastructure() {
        store.store(factory: Factory(type: RealmAccessor.self) { _, _ in
            RealmAccessorImpl()
        })
        store.store(factory: Factory(type: PHAssetReading.self) { _, _ in
            PHAssetReaderImpl()
        })
        store.store(factory: Factory(type: PHAssetExporting.self) { _, _ in
            PHAssetExporterImpl()
        })
        // Observer long-lived — partagé entre les vues (TimelineViewModel le démarre
        // à l'auth) et le scheduler BG. Singleton-by-closure (cf. `registerGallery`)
        // pour que `startObserving()` reste idempotent.
        var sharedObserver: PhotoLibraryObserverImpl?
        store.store(factory: Factory(type: PhotoLibraryObserving.self) { _, _ in
            if let existing = sharedObserver { return existing }
            let new = PhotoLibraryObserverImpl(
                backupQueueWriter: resolve(),
                settings: resolve()
            )
            sharedObserver = new
            return new
        })
    }

    private static func registerAuth(config: AuthConfig) {
        store.store(factory: Factory(type: TokenStorage.self) { _, _ in
            KeychainTokenStorage()
        })
        store.store(factory: Factory(type: OAuth2Client.self) { _, _ in
            OAuth2Client(config: config)
        })
        store.store(factory: Factory(type: AuthService.self) { _, _ in
            AuthServiceImpl(
                config: config,
                oauth: resolve(),
                storage: resolve()
            )
        })
    }

    private static func registerApiLayer() {
        // Fetcher branché à l'interceptor qui ajoute le Bearer et gère 401 → refresh.
        store.store(factory: Factory(type: PhotoApiFetching.self) { _, _ in
            let auth: AuthService = resolve()
            return PhotoApiFetcher(interceptor: AuthInterceptor(auth: auth))
        })
    }

    private static func registerManagers() {
        store.store(factory: Factory(type: PhotoReading.self) { _, _ in
            PhotoManagerImpl(realm: resolve())
        })
        store.store(factory: Factory(type: PhotoWriting.self) { _, _ in
            PhotoManagerImpl(realm: resolve())
        })
        // `PhotoManagerImpl` implémente aussi `BackupQueueReading/Writing` —
        // `RealmAccessor` est partagé entre instances donc le state est cohérent
        // même si le resolver retourne plusieurs instances par type-key.
        store.store(factory: Factory(type: BackupQueueReading.self) { _, _ in
            PhotoManagerImpl(realm: resolve())
        })
        store.store(factory: Factory(type: BackupQueueWriting.self) { _, _ in
            PhotoManagerImpl(realm: resolve())
        })
        // Idem pour la file de suppression — réutilise `PhotoManagerImpl` qui
        // implémente aussi `DeletionQueueReading/Writing`.
        store.store(factory: Factory(type: DeletionQueueReading.self) { _, _ in
            PhotoManagerImpl(realm: resolve())
        })
        store.store(factory: Factory(type: DeletionQueueWriting.self) { _, _ in
            PhotoManagerImpl(realm: resolve())
        })
        store.store(factory: Factory(type: TimelineReading.self) { _, _ in
            TimelineManagerImpl(realm: resolve())
        })
        store.store(factory: Factory(type: AlbumManaging.self) { _, _ in
            AlbumManagerImpl(realm: resolve(), api: resolve())
        })
        store.store(factory: Factory(type: DriveManaging.self) { _, _ in
            DriveManagerImpl(realm: resolve(), api: resolve())
        })
        store.store(factory: Factory(type: MediaDownloading.self) { _, _ in
            MediaDownloadManager(api: resolve(), auth: resolve())
        })
    }

    /// Shim qui matérialise un singleton partagé entre plusieurs protocoles
    /// (Reading/Writing/Managing). Le resolver SimpleResolver cache par *type-key*,
    /// donc enregistrer 3 factories produirait 3 instances. On retient la première
    /// création dans une closure capturée.
    private static func registerGallery() {
        // SyncSettings — un seul SyncSettingsManagerImpl exposé via les trois protocoles.
        var sharedSettings: SyncSettingsManagerImpl?
        let settingsFactory: () -> SyncSettingsManagerImpl = {
            if let existing = sharedSettings { return existing }
            let new = SyncSettingsManagerImpl(realm: resolve())
            sharedSettings = new
            return new
        }
        store.store(factory: Factory(type: SyncSettingsReading.self) { _, _ in settingsFactory() })
        store.store(factory: Factory(type: SyncSettingsWriting.self) { _, _ in settingsFactory() })

        // UploadQueue — idem, état partagé entre lecteur (UI) et écrivain (sync engine).
        var sharedQueue: UploadQueueImpl?
        let queueFactory: () -> UploadQueueImpl = {
            if let existing = sharedQueue { return existing }
            let new = UploadQueueImpl()
            sharedQueue = new
            return new
        }
        store.store(factory: Factory(type: UploadQueueReading.self) { _, _ in queueFactory() })
        store.store(factory: Factory(type: UploadQueueWriting.self) { _, _ in queueFactory() })

        store.store(factory: Factory(type: NetworkReachable.self) { _, _ in
            NetworkReachabilityImpl()
        })
        store.store(factory: Factory(type: GalleryComposing.self) { _, _ in
            GalleryComposerImpl()
        })
    }

    private static func registerSync() {
        store.store(factory: Factory(type: PhotoSyncing.self) { _, _ in
            PhotoSyncEngine(
                api: resolve(),
                photoReader: resolve(),
                photoWriter: resolve(),
                backupQueueReader: resolve(),
                backupQueueWriter: resolve(),
                assetReader: resolve(),
                exporter: resolve(),
                settings: resolve(),
                reachability: resolve(),
                uploadQueue: resolve()
            )
        })
        store.store(factory: Factory(type: BackgroundSyncScheduling.self) { _, _ in
            BackgroundSyncScheduler(
                settings: resolve(),
                drives: resolve(),
                sync: resolve(),
                reachability: resolve()
            )
        })
        // Engine de suppression — un singleton suffit (verrou `isDraining`
        // interne empêche les drains concurrents). Pendant de `PhotoSyncing`.
        var sharedDeletion: PhotoDeletionEngine?
        store.store(factory: Factory(type: PhotoDeleting.self) { _, _ in
            if let existing = sharedDeletion { return existing }
            let new = PhotoDeletionEngine(
                api: resolve(),
                deletionQueueReader: resolve(),
                deletionQueueWriter: resolve()
            )
            sharedDeletion = new
            return new
        })
    }

    /// Helper de résolution typée depuis le resolver partagé.
    /// Toute absence de registration ici est un bug structurel détecté au démarrage.
    private static func resolve<T>() -> T {
        do {
            return try store.resolve(
                type: T.self,
                forCustomTypeIdentifier: nil,
                factoryParameters: nil,
                resolver: store
            )
        } catch {
            preconditionFailure("Missing DI registration for \(T.self): \(error)")
        }
    }
}
