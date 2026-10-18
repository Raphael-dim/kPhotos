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
import RealmSwift

public enum PhotoSyncStatus: String {
    case pending
    case uploading
    case synced
    case error
}

public final class Photo: Object {
    @Persisted(primaryKey: true)
    public var fileId: String = ""
    @Persisted public var driveId: Int = 0
    @Persisted public var localIdentifier: String = ""
    @Persisted public var name: String = ""
    @Persisted public var libraryRootId: String = ""
    @Persisted public var isAvailable: Bool = true
    @Persisted public var contentSHA256: String = ""
    @Persisted public var remoteRevision: String = ""
    @Persisted public var resourceRevisionsJSON: String = "{}"
    @Persisted public var localModifiedAt: Date?
    @Persisted public var backupComplete: Bool = false
    @Persisted public var resourceFileIds: List<String>

    /// Date de prise de vue (PHAsset.creationDate). Source de vérité pour la timeline.
    @Persisted public var takenAt: Date = .init()
    @Persisted public var captureDateSource: String = ""
    @Persisted public var latitude: Double?
    @Persisted public var longitude: Double?
    @Persisted public var locationSource: String = ""
    @Persisted public var thumbnailPackJSON: String = ""
    @Persisted public var embeddedMetadataJSON: String = ""
    @Persisted public var embeddedMetadataRevision: String = ""
    @Persisted public var uploadedAt: Date = .init()

    @Persisted public var mimeType: String = ""
    @Persisted public var size: Int64 = 0
    @Persisted public var thumbnailUrl: String = ""

    @Persisted public var isVideo: Bool = false
    @Persisted public var duration: Double = 0

    @Persisted public var albumIds: List<String>

    @Persisted public var syncStatusRaw: String = PhotoSyncStatus.synced.rawValue
    @Persisted public var isFavorite: Bool = false

    public var syncStatus: PhotoSyncStatus {
        get { PhotoSyncStatus(rawValue: syncStatusRaw) ?? .error }
        set { syncStatusRaw = newValue.rawValue }
    }
}

/// Représentation thread-safe d'une `Photo`. Cf. AGENTS.md §21 (Realm thread-safety).
/// Construite à l'intérieur d'un block Realm puis renvoyée à travers les frontières async.
public struct PhotoSnapshot: Identifiable, Equatable, Sendable {
    public let id: String // == fileId, pour Identifiable
    public let driveId: Int
    public let localIdentifier: String
    public let name: String
    public var libraryRootId: String = ""
    public var isAvailable: Bool = true
    public var contentSHA256: String = ""
    public var remoteRevision: String = ""
    public var resourceRevisions: [String: String] = [:]
    public var localModifiedAt: Date?
    public var backupComplete: Bool = false
    public var resourceFileIds: [String] = []
    public let takenAt: Date
    public var captureDateSource: String = ""
    public var coordinate: MediaCoordinate?
    public var locationSource: String = ""
    public var thumbnailPack: ThumbnailPackReference?
    public var embeddedMetadataJSON: String = ""
    public var embeddedMetadataRevision: String = ""
    /// Derived from the original's cached metadata, never from its filename.
    public var liveContentIdentifier: String = ""
    /// Transient viewer/restoration link; the motion remains a separate cloud original.
    public var liveMotionFileId: String?
    public var liveMotionName: String?
    public var embeddedMetadata: EmbeddedMediaMetadata? {
        try? JSONDecoder().decode(EmbeddedMediaMetadata.self, from: Data(embeddedMetadataJSON.utf8))
    }

    public var hasReliableCaptureDate: Bool { ["photokit", "embedded_offset"].contains(captureDateSource) }
    public let uploadedAt: Date
    public let mimeType: String
    public let size: Int64
    public let isVideo: Bool
    public let duration: Double
    public let albumIds: [String]
    public let syncStatus: PhotoSyncStatus
    public let isFavorite: Bool

    public var fileId: String { id }

    public init(
        id: String,
        driveId: Int,
        localIdentifier: String,
        name: String,
        takenAt: Date,
        uploadedAt: Date,
        mimeType: String,
        size: Int64,
        isVideo: Bool,
        duration: Double,
        albumIds: [String],
        syncStatus: PhotoSyncStatus,
        isFavorite: Bool
    ) {
        self.id = id
        self.driveId = driveId
        self.localIdentifier = localIdentifier
        self.name = name
        self.takenAt = takenAt
        self.uploadedAt = uploadedAt
        self.mimeType = mimeType
        self.size = size
        self.isVideo = isVideo
        self.duration = duration
        self.albumIds = albumIds
        self.syncStatus = syncStatus
        self.isFavorite = isFavorite
    }

    /// Construire depuis un Photo Realm — n'utiliser qu'à l'intérieur d'un block `realm.read`.
    init(_ photo: Photo) {
        self.init(
            id: photo.fileId,
            driveId: photo.driveId,
            localIdentifier: photo.localIdentifier,
            name: photo.name,
            takenAt: photo.takenAt,
            uploadedAt: photo.uploadedAt,
            mimeType: photo.mimeType,
            size: photo.size,
            isVideo: photo.isVideo,
            duration: photo.duration,
            albumIds: Array(photo.albumIds),
            syncStatus: photo.syncStatus,
            isFavorite: photo.isFavorite
        )
        self.captureDateSource = photo.captureDateSource
        if let lat = photo.latitude, let lon = photo.longitude {
            self.coordinate = MediaCoordinate(latitude: lat, longitude: lon)
        }
        self.locationSource = photo.locationSource
        self.thumbnailPack = photo.thumbnailPackJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode(
            ThumbnailPackReference.self,
            from: $0
        )
        }
        self.embeddedMetadataJSON = photo.embeddedMetadataJSON
        self.embeddedMetadataRevision = photo.embeddedMetadataRevision
        self.liveContentIdentifier = embeddedMetadata?.livePhotoContentIdentifier ?? ""
        self.libraryRootId = photo.libraryRootId
        self.isAvailable = photo.isAvailable
        self.contentSHA256 = photo.contentSHA256
        self.remoteRevision = photo.remoteRevision
        self.localModifiedAt = photo.localModifiedAt
        self.resourceRevisions = (try? JSONDecoder().decode(
            [String: String].self,
            from: Data(photo.resourceRevisionsJSON.utf8)
        )) ?? [:]
        self.backupComplete = photo.backupComplete
        self.resourceFileIds = Array(photo.resourceFileIds)
    }
}

/// État d'un item dans la file de sauvegarde persistante.
public enum BackupItemState: String, Sendable {
    /// En attente d'upload. État initial à l'enqueue.
    case queued
    /// Tentative d'upload en cours côté worker. Transient — ne survit pas à un crash.
    case uploading
    /// Upload réussi — le `Photo` Realm correspondant existe désormais.
    case completed
    /// Échec transient (réseau, 5xx, 429, iCloud-not-downloaded, etc.) — sera
    /// réessayé automatiquement après `BackupItem.nextRetryAt`. Visuellement
    /// silencieux côté UI (pas de badge orange) tant qu'on n'a pas atteint le
    /// plafond de tentatives, comme Google Photos qui ne harcèle pas l'utilisateur
    /// sur les flakes transients.
    case failedTransient
    /// Échec non récupérable (format invalide, asset corrompu, 4xx définitif,
    /// ou plafond de retries transients atteint). Le badge orange tappable
    /// expose la cause et un futur écran "Statut de sauvegarde" permettra
    /// retry / skip manuels (Phase 2b).
    case failedPermanent
    /// Item retiré de la file par décision utilisateur ou parce que l'asset
    /// PHAsset source n'existe plus localement. Ne sera plus tenté.
    case skipped
}

/// File de sauvegarde persistée — source unique de vérité pour le statut de
/// chaque média côté client. Indexée par `localIdentifier` du PHAsset.
///
/// Remplace l'ancien doublon `UploadQueue` (in-memory) + `FailedUpload` (Realm)
/// par un modèle unifié qui survit aux redémarrages et aux sessions de sync.
///
/// `clientToken` est généré une seule fois à l'enqueue et persisté pour toute
/// la durée de vie de l'item — c'est l'idempotency key de l'API kDrive (cf.
/// `Endpoint.upload`). Un retry après réponse perdue côté réseau retombera sur
/// le même token et le serveur retournera le fichier déjà créé au lieu d'en
/// faire un doublon.
public final class BackupItem: Object {
    @Persisted(primaryKey: true)
    public var localIdentifier: String = ""
    @Persisted public var stateRaw: String = BackupItemState.queued.rawValue
    @Persisted public var clientToken: String = ""
    @Persisted public var enqueuedAt: Date = .init()
    /// Date de prise de vue (PHAsset.creationDate) — utilisée pour trier la file
    /// anti-chronologiquement (newest first, comme Google Photos).
    @Persisted public var creationDate: Date = .init()
    @Persisted public var isVideo: Bool = false
    @Persisted public var attemptCount: Int = 0
    @Persisted public var lastAttemptAt: Date?
    /// Pour les items `.failedTransient` : moment à partir duquel le worker peut
    /// réessayer. `nil` pour tous les autres états. Filtré dans `nextProcessable`.
    @Persisted public var nextRetryAt: Date?
    /// Message lisible utilisateur (cf. `ExportError.errorDescription` ou
    /// `PhotoAPIError.errorDescription`). Vide tant qu'aucun échec n'a eu lieu.
    @Persisted public var lastErrorReason: String = ""

    public var state: BackupItemState {
        get { BackupItemState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }
}

/// État d'un item dans la file de suppression persistante. Miroir de `BackupItemState`
/// côté lifecycle (queued → deleting → completed | failedTransient | failedPermanent).
/// Pas de `.skipped` : on ne "skip" pas une suppression — l'utilisateur peut juste
/// annuler avant que l'engine ne pousse côté API (état `.queued`).
public enum DeletionItemState: String, Sendable {
    /// Suppression demandée, pas encore tentée. Annulable (cancel = supprimer l'entry).
    case queued
    /// Suppression en cours côté worker. Transient — ne survit pas à un crash.
    case deleting
    /// Suppression réussie côté kDrive — le `DeletionItem` est purgé immédiatement
    /// après par l'engine en même temps qu'il delete le `Photo` correspondant.
    /// Cet état existe surtout pour rendre les transitions atomiques côté Realm.
    case completed
    /// Échec transient (réseau, 5xx, 429) — sera retenté automatiquement après
    /// `nextRetryAt`. Visuellement signalé d'un badge gris discret (la photo
    /// est toujours visible mais grisée).
    case failedTransient
    /// Échec définitif (4xx, droits, plafond transients atteint). Badge rouge
    /// tappable expose la cause et offre retry / annuler.
    case failedPermanent
}

/// File de suppression persistée — symétrique à `BackupItem` côté lifecycle.
/// Indexée par `fileId` (clé primaire kDrive) plutôt que `localIdentifier` :
/// (a) on peut supprimer une photo `cloudOnly` sans PHAsset local ; (b) la
/// vue principale identifie les items à supprimer par leur `cloudFileId`.
///
/// Cas d'usage de la persistance : l'utilisateur sélectionne 200 photos, l'app
/// crash mi-batch. Au redémarrage, l'engine reprend là où il s'est arrêté
/// — au lieu de laisser 150 photos zombies "supprimées côté UI mais toujours
/// présentes côté serveur".
public final class DeletionItem: Object {
    @Persisted(primaryKey: true)
    public var fileId: String = ""
    @Persisted public var driveId: Int = 0
    /// `localIdentifier` du PHAsset associé, vide si aucune (cas `cloudOnly`).
    /// Conservé pour pouvoir afficher la pré-suppression dans la galerie locale
    /// (badge "deletion in progress" sur la tile correspondante).
    @Persisted public var localIdentifier: String = ""
    @Persisted public var stateRaw: String = DeletionItemState.queued.rawValue
    @Persisted public var enqueuedAt: Date = .init()
    @Persisted public var attemptCount: Int = 0
    @Persisted public var lastAttemptAt: Date?
    /// Pour `.failedTransient` : moment à partir duquel le worker peut réessayer.
    /// `nil` pour tous les autres états.
    @Persisted public var nextRetryAt: Date?
    /// Message lisible utilisateur (cf. `PhotoAPIError.errorDescription`).
    @Persisted public var lastErrorReason: String = ""

    public var state: DeletionItemState {
        get { DeletionItemState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }
}

public struct DeletionItemSnapshot: Equatable, Sendable {
    public let fileId: String
    public let driveId: Int
    public let localIdentifier: String
    public let state: DeletionItemState
    public let enqueuedAt: Date
    public let attemptCount: Int
    public let lastAttemptAt: Date?
    public let nextRetryAt: Date?
    public let lastErrorReason: String

    public init(
        fileId: String,
        driveId: Int,
        localIdentifier: String,
        state: DeletionItemState,
        enqueuedAt: Date,
        attemptCount: Int,
        lastAttemptAt: Date?,
        nextRetryAt: Date?,
        lastErrorReason: String
    ) {
        self.fileId = fileId
        self.driveId = driveId
        self.localIdentifier = localIdentifier
        self.state = state
        self.enqueuedAt = enqueuedAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
        self.lastErrorReason = lastErrorReason
    }

    init(_ entity: DeletionItem) {
        self.init(
            fileId: entity.fileId,
            driveId: entity.driveId,
            localIdentifier: entity.localIdentifier,
            state: entity.state,
            enqueuedAt: entity.enqueuedAt,
            attemptCount: entity.attemptCount,
            lastAttemptAt: entity.lastAttemptAt,
            nextRetryAt: entity.nextRetryAt,
            lastErrorReason: entity.lastErrorReason
        )
    }
}

public struct BackupItemSnapshot: Equatable, Sendable {
    public let localIdentifier: String
    public let state: BackupItemState
    public let clientToken: String
    public let enqueuedAt: Date
    public let creationDate: Date
    public let isVideo: Bool
    public let attemptCount: Int
    public let lastAttemptAt: Date?
    public let nextRetryAt: Date?
    public let lastErrorReason: String

    public init(
        localIdentifier: String,
        state: BackupItemState,
        clientToken: String,
        enqueuedAt: Date,
        creationDate: Date,
        isVideo: Bool,
        attemptCount: Int,
        lastAttemptAt: Date?,
        nextRetryAt: Date?,
        lastErrorReason: String
    ) {
        self.localIdentifier = localIdentifier
        self.state = state
        self.clientToken = clientToken
        self.enqueuedAt = enqueuedAt
        self.creationDate = creationDate
        self.isVideo = isVideo
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
        self.lastErrorReason = lastErrorReason
    }

    init(_ entity: BackupItem) {
        self.init(
            localIdentifier: entity.localIdentifier,
            state: entity.state,
            clientToken: entity.clientToken,
            enqueuedAt: entity.enqueuedAt,
            creationDate: entity.creationDate,
            isVideo: entity.isVideo,
            attemptCount: entity.attemptCount,
            lastAttemptAt: entity.lastAttemptAt,
            nextRetryAt: entity.nextRetryAt,
            lastErrorReason: entity.lastErrorReason
        )
    }
}
