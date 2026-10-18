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

/// État de synchronisation d'un élément de galerie tel que rendu à l'UI.
public enum GalleryItemSyncState: Equatable, Sendable {
    /// Local non encore connu de la file d'upload (sera planifié au prochain run).
    case localOnly
    /// Dans la file d'attente, pas encore commencé.
    case pendingUpload
    /// Upload en cours. `fraction` est `nil` si on ne le sait pas (upload non chunked).
    case uploading(fraction: Double?)
    /// Échec — on garde le média visible mais signalé.
    case uploadFailed(reason: String)
    /// Synchronisé : présent localement ET sur le cloud (jointure par localIdentifier).
    case synced
    /// Cloud uniquement : présent sur kDrive, pas/plus dans la photothèque iOS
    /// (ex: photo prise depuis un autre device, déjà supprimée localement).
    case cloudOnly
    /// Suppression demandée par l'utilisateur, pas encore tentée côté serveur.
    /// Visuel : badge animé trash + tile grisée. Annulable tant qu'on est dans cet état.
    case deletionPending
    /// Suppression en cours côté serveur. Visuel : spinner sur badge trash.
    case deleting
    /// Suppression échouée définitivement. Visuel : badge rouge tappable
    /// → sheet avec actions retry / annuler / voir l'erreur.
    case deletionFailed(reason: String)
}

/// Modèle unifié exposé à la galerie. Construit en mémoire par `GalleryComposer`
/// — n'est jamais persisté. Source de vérité :
/// - photo locale : `PHAsset` (lecture via PhotoKit, pas via Realm)
/// - photo cloud : `Photo` Realm
///
/// La clé `id` est stable sur le cycle de vie de l'item :
/// - si on a un `localIdentifier`, on l'utilise (un même asset reste identifiable
///   même quand son état passe de `localOnly` à `synced`)
/// - sinon on dérive l'id du `cloudFileId`.
public struct GalleryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let takenAt: Date
    public let isVideo: Bool
    public let localAssetIdentifier: String?
    public let cloudFileId: String?
    public let cloudDriveId: Int?
    public let syncState: GalleryItemSyncState

    public init(
        id: String,
        takenAt: Date,
        isVideo: Bool,
        localAssetIdentifier: String?,
        cloudFileId: String?,
        cloudDriveId: Int?,
        syncState: GalleryItemSyncState
    ) {
        self.id = id
        self.takenAt = takenAt
        self.isVideo = isVideo
        self.localAssetIdentifier = localAssetIdentifier
        self.cloudFileId = cloudFileId
        self.cloudDriveId = cloudDriveId
        self.syncState = syncState
    }

    /// Identifiant d'un item cloud-only de la timeline (photo présente sur kDrive
    /// mais plus dans la photothèque iOS). Centralisé ici car deux endroits
    /// doivent rester d'accord sur le format :
    /// - `GalleryComposer.merge` qui construit l'item ;
    /// - `TimelineViewModel.selectedPhotos` qui résout la sélection en sens inverse.
    /// Un item synced utilise au contraire son `localIdentifier` brut comme `id`.
    public static func cloudOnlyID(fileId: String) -> String {
        "cloud-\(fileId)"
    }

    /// Construit un item depuis un `PhotoSnapshot` cloud — pour les vues qui
    /// n'ont pas accès au `GalleryComposer` (ex: `AlbumDetailView`). Force le
    /// `syncState` à `.synced` pour ne pas afficher de badge (toutes les photos
    /// d'un album sont par définition déjà sur kDrive).
    public static func fromCloud(_ photo: PhotoSnapshot) -> GalleryItem {
        GalleryItem(
            id: photo.fileId,
            takenAt: photo.takenAt,
            isVideo: photo.isVideo,
            localAssetIdentifier: nil,
            cloudFileId: photo.fileId,
            cloudDriveId: photo.driveId,
            syncState: .synced
        )
    }
}

/// Média prêt à être affiché par le viewer plein écran — unifie la photo cloud
/// (kDrive) et l'asset local (PhotoKit) derrière un même type. Permet au viewer
/// d'ignorer la provenance et de laisser le chargeur de chaque page choisir
/// la bonne stratégie (preview API vs `PHImageManager`).
public enum ViewerMedia: Identifiable, Equatable, Sendable {
    case cloud(PhotoSnapshot)
    case local(LocalAssetSnapshot)

    public var id: String {
        switch self {
        case .cloud(let snapshot): return "cloud-\(snapshot.fileId)"
        case .local(let asset): return "local-\(asset.localIdentifier)"
        }
    }

    public var takenAt: Date {
        switch self {
        case .cloud(let snapshot): return snapshot.takenAt
        case .local(let asset): return asset.takenAt
        }
    }

    public var isVideo: Bool {
        switch self {
        case .cloud(let snapshot): return snapshot.isVideo
        case .local(let asset): return asset.isVideo
        }
    }

    /// `true` quand le média est synchronisé sur kDrive — utilisé pour activer
    /// les actions qui ciblent l'API distante (delete, ajout à un album).
    public var isCloudBacked: Bool {
        if case .cloud = self { return true }
        return false
    }
}

/// Section temporelle prête à afficher (un mois calendaire).
public struct GallerySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let year: Int
    public let month: Int
    public let items: [GalleryItem]

    public init(year: Int, month: Int, items: [GalleryItem]) {
        self.id = "\(year)-\(String(format: "%02d", month))"
        self.year = year
        self.month = month
        self.items = items
    }
}
