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
import Photos

/// État de l'autorisation d'accès à la photothèque, mappé de `PHAuthorizationStatus`.
/// Garde une enum simple côté kPhotosCore — évite d'exposer Photos dans toute l'app.
public enum PhotoLibraryAuthorization: Equatable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized
}

/// Petit résumé de la photothèque locale, source des candidats d'upload.
public struct PhotoLibrarySummary: Equatable {
    public let totalAssets: Int
    public let photosCount: Int
    public let videosCount: Int

    public init(totalAssets: Int, photosCount: Int, videosCount: Int) {
        self.totalAssets = totalAssets
        self.photosCount = photosCount
        self.videosCount = videosCount
    }

    public static let empty = PhotoLibrarySummary(totalAssets: 0, photosCount: 0, videosCount: 0)
}

/// Snapshot thread-safe d'un PHAsset — n'expose pas le type Photos vers Core/UI.
/// Construit en lecture seule depuis PhotoKit, sans aller chercher les binaires.
public struct LocalAssetSnapshot: Identifiable, Equatable, Sendable {
    public let id: String // == localIdentifier
    public let localIdentifier: String
    public let takenAt: Date
    public let isVideo: Bool

    public init(localIdentifier: String, takenAt: Date, isVideo: Bool) {
        self.id = localIdentifier
        self.localIdentifier = localIdentifier
        self.takenAt = takenAt
        self.isVideo = isVideo
    }
}

/// Coordonnée GPS d'un asset local. Volontairement plain Double (pas
/// `CLLocationCoordinate2D` qui n'est pas Sendable) pour traverser les
/// frontières async/await sans warning.
public struct AssetLocation: Equatable, Sendable, Hashable {
    public let localIdentifier: String
    public let latitude: Double
    public let longitude: Double

    public init(localIdentifier: String, latitude: Double, longitude: Double) {
        self.localIdentifier = localIdentifier
        self.latitude = latitude
        self.longitude = longitude
    }
}

public protocol PHAssetReading: AnyObject {
    func currentAuthorization() -> PhotoLibraryAuthorization
    func requestAuthorization() async -> PhotoLibraryAuthorization
    func summary() async -> PhotoLibrarySummary

    /// Liste tous les assets locaux pertinents (photos + vidéos de la photothèque
    /// utilisateur) avec leur `creationDate` pour la timeline.
    /// `filter` permet de ne charger que photos / vidéos / les deux selon les réglages.
    func fetchAssetSnapshots(filter: SyncMediaFilter) async -> [LocalAssetSnapshot]

    /// Récupère les coordonnées GPS pour les assets correspondants — uniquement
    /// ceux qui ont effectivement une `location` non nulle dans PhotoKit.
    /// Utilisé par la vue Carte pour matcher les photos kDrive (PhotoSnapshot)
    /// avec leur localisation conservée par iOS dans l'index PhotoKit.
    func fetchLocations(forLocalIdentifiers identifiers: [String]) async -> [AssetLocation]
}

public final class PHAssetReaderImpl: PHAssetReading {
    public init() {}

    public func currentAuthorization() -> PhotoLibraryAuthorization {
        let raw = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return Self.map(raw)
    }

    public func requestAuthorization() async -> PhotoLibraryAuthorization {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    public func summary() async -> PhotoLibrarySummary {
        guard currentAuthorization() == .authorized || currentAuthorization() == .limited else {
            return .empty
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]

        let allAssets = PHAsset.fetchAssets(with: options)
        var photos = 0
        var videos = 0
        allAssets.enumerateObjects { asset, _, _ in
            switch asset.mediaType {
            case .image: photos += 1
            case .video: videos += 1
            default: break
            }
        }
        return PhotoLibrarySummary(
            totalAssets: photos + videos,
            photosCount: photos,
            videosCount: videos
        )
    }

    public func fetchAssetSnapshots(filter: SyncMediaFilter) async -> [LocalAssetSnapshot] {
        guard currentAuthorization() == .authorized || currentAuthorization() == .limited else {
            return []
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        // PHFetchOptions ne supporte pas un OR natif sur mediaType — on prédicate
        // sur la valeur brute. (PHAssetMediaType.image.rawValue == 1, .video == 2).
        switch filter {
        case .photosOnly:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videosOnly:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        default:
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        }

        let fetchResult = PHAsset.fetchAssets(with: options)
        var snapshots: [LocalAssetSnapshot] = []
        snapshots.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            snapshots.append(LocalAssetSnapshot(
                localIdentifier: asset.localIdentifier,
                takenAt: date,
                isVideo: asset.mediaType == .video
            ))
        }
        return snapshots
    }

    public func fetchLocations(forLocalIdentifiers identifiers: [String]) async -> [AssetLocation] {
        guard currentAuthorization() == .authorized || currentAuthorization() == .limited else {
            return []
        }
        guard !identifiers.isEmpty else { return [] }

        // PHAsset.fetchAssets supporte un batch fetch — bien plus rapide que N appels.
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var locations: [AssetLocation] = []
        locations.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            guard let loc = asset.location else { return }
            locations.append(AssetLocation(
                localIdentifier: asset.localIdentifier,
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude
            ))
        }
        return locations
    }

    static func map(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }
}

// MARK: - PhotoLibraryObserver

/// Observe la photothèque iOS et enqueue automatiquement les nouveaux assets dans
/// la file de sauvegarde. Phase 1b du backup queue redesign — sans ça, l'utilisateur
/// doit fermer/rouvrir l'app (ou pull-to-refresh) pour que les photos qu'il vient
/// de prendre entrent dans la file.
///
/// Comportement Google Photos : tu prends une photo, le badge "en attente" apparaît
/// à la seconde, l'upload démarre au prochain coup de moteur (sync manuelle ou BG).
public protocol PhotoLibraryObserving: AnyObject {
    /// Démarre l'observation. Idempotent — appels multiples sont sans effet après
    /// le premier. Exige que l'autorisation photothèque soit accordée (sinon no-op).
    func startObserving()

    /// Arrête l'observation et libère le `PHFetchResult` tracké. Appelé typiquement
    /// quand l'autorisation est révoquée (réglages iOS). Phase 1b laisse cette
    /// méthode publique pour les futurs cas (logout, etc.).
    func stopObserving()

    /// Stop + start. À appeler quand un réglage qui influe sur le `PHFetchOptions`
    /// du `trackedAssets` change (ex: `SyncSettings.mediaFilter` toggle photo→vidéo).
    /// Sans ça, le filtre actif resterait celui en vigueur au lancement de l'app.
    func restart()
}

public final class PhotoLibraryObserverImpl: NSObject, PhotoLibraryObserving, PHPhotoLibraryChangeObserver {
    private let backupQueueWriter: BackupQueueWriting
    private let settings: SyncSettingsReading

    /// `PHFetchResult` long-lived utilisé pour calculer les deltas. Réinitialisé
    /// à chaque `startObserving()` ou changement de filtre média. PhotoKit ne donne
    /// pas de notification "tout asset modifié" — on doit garder un snapshot stable
    /// pour que `PHChange.changeDetails(for:)` puisse calculer un diff.
    private var trackedAssets: PHFetchResult<PHAsset>?
    private var isObserving = false

    public init(backupQueueWriter: BackupQueueWriting, settings: SyncSettingsReading) {
        self.backupQueueWriter = backupQueueWriter
        self.settings = settings
        super.init()
    }

    deinit {
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    public func startObserving() {
        guard !isObserving else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let mediaFilter = (try? settings.current().mediaFilter) ?? .both
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = Self.predicate(for: mediaFilter)

        trackedAssets = PHAsset.fetchAssets(with: options)
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    public func stopObserving() {
        guard isObserving else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        trackedAssets = nil
        isObserving = false
    }

    public func restart() {
        stopObserving()
        startObserving()
    }

    /// Callback appelé par PhotoKit sur un thread interne (PAS le main thread).
    /// On délègue l'enqueue à une `Task` (qui finit par hit Realm via `RealmAccessor`
    /// qui dispatche sur sa propre queue de write — pas de risque de race).
    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let current = trackedAssets,
              let details = changeInstance.changeDetails(for: current) else { return }

        // Capturer AVANT de réassigner trackedAssets, sinon les objets observés
        // pointent vers l'ancienne fetch.
        let inserted: [PHAsset] = details.insertedObjects
        let removed: [PHAsset] = details.removedObjects

        trackedAssets = details.fetchResultAfterChanges

        if !inserted.isEmpty {
            Task { [backupQueueWriter] in
                for asset in inserted {
                    // Pas de `creationDate` → on saute (sera retenté au prochain
                    // `reconcile()` qui tente la même garde côté `PhotoSyncEngine`).
                    guard let createdAt = asset.creationDate else { continue }
                    try? await backupQueueWriter.enqueueIfAbsent(
                        localIdentifier: asset.localIdentifier,
                        creationDate: createdAt,
                        isVideo: asset.mediaType == .video
                    )
                }
            }
        }

        if !removed.isEmpty {
            // Asset supprimé localement → `markSkipped`. Idempotent côté impl
            // (no-op si pas d'entrée). Pour un asset déjà `.completed` côté
            // BackupItem, le composer continue à afficher `.synced` parce que
            // la présence cloud gagne — donc marquer skipped n'affecte pas l'UX
            // mais évite que la file traîne des entrées orphelines.
            Task { [backupQueueWriter] in
                for asset in removed {
                    try? await backupQueueWriter.markSkipped(
                        localIdentifier: asset.localIdentifier,
                        reason: "Photo supprimée localement."
                    )
                }
            }
        }
    }

    static func predicate(for filter: SyncMediaFilter) -> NSPredicate {
        switch filter {
        case .photosOnly:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videosOnly:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        default:
            return NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        }
    }
}
