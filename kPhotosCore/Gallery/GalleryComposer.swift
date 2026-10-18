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

public protocol GalleryComposing: AnyObject {
    /// Construit la galerie unifiée à partir des sources de vérité :
    /// - photothèque locale (PHAsset) — index iOS, lecture rapide
    /// - cloud (Realm Photo) — état persisté des médias kDrive
    /// - file de sauvegarde persistée (Realm BackupItem) — source de vérité du
    ///   statut local : `.queued`, `.uploading`, `.completed`, `.failedPermanent`,
    ///   `.skipped`. Survit aux redémarrages et aux sessions de sync.
    /// - file de suppression persistée (Realm DeletionItem) — indexée par
    ///   `fileId`, source de vérité du statut "en cours de suppression" :
    ///   `.queued`, `.deleting`, `.failedTransient`, `.failedPermanent`. Les
    ///   items `.completed` sont purgés et n'apparaissent jamais ici (le Photo
    ///   correspondant a été supprimé dans la même transaction).
    /// - file d'upload transient (UploadQueue in-memory) — signal éphémère pour
    ///   afficher le spinner sur la tuile pendant qu'un upload est actif. Phase 2
    ///   pourra remplacer ce mécanisme par une observation directe de BackupItem.
    ///
    /// Pure : pas d'I/O. Synchrone. Testable sans Realm ni PhotoKit.
    func compose(
        localAssets: [LocalAssetSnapshot],
        cloudPhotos: [PhotoSnapshot],
        backupItems: [String: BackupItemSnapshot],
        deletionItems: [String: DeletionItemSnapshot],
        uploadStates: [String: UploadState],
        calendar: Calendar
    ) -> [GallerySection]
}

public extension GalleryComposing {
    /// Surcharge de compat pour les tests existants qui n'ont ni queue ni runtime —
    /// équivalent à "rien en file, rien en cours".
    func compose(
        localAssets: [LocalAssetSnapshot],
        cloudPhotos: [PhotoSnapshot],
        uploadStates: [String: UploadState],
        calendar: Calendar
    ) -> [GallerySection] {
        compose(
            localAssets: localAssets,
            cloudPhotos: cloudPhotos,
            backupItems: [:],
            deletionItems: [:],
            uploadStates: uploadStates,
            calendar: calendar
        )
    }

    /// Surcharge de compat — appelée par les call-sites existants qui n'ont pas
    /// encore la file de suppression. À supprimer une fois le rollout terminé.
    func compose(
        localAssets: [LocalAssetSnapshot],
        cloudPhotos: [PhotoSnapshot],
        backupItems: [String: BackupItemSnapshot],
        uploadStates: [String: UploadState],
        calendar: Calendar
    ) -> [GallerySection] {
        compose(
            localAssets: localAssets,
            cloudPhotos: cloudPhotos,
            backupItems: backupItems,
            deletionItems: [:],
            uploadStates: uploadStates,
            calendar: calendar
        )
    }
}

public final class GalleryComposerImpl: GalleryComposing {
    public init() {}

    public func compose(
        localAssets: [LocalAssetSnapshot],
        cloudPhotos: [PhotoSnapshot],
        backupItems: [String: BackupItemSnapshot],
        deletionItems: [String: DeletionItemSnapshot],
        uploadStates: [String: UploadState],
        calendar: Calendar
    ) -> [GallerySection] {
        let items = Self.merge(
            localAssets: localAssets,
            cloudPhotos: cloudPhotos,
            backupItems: backupItems,
            deletionItems: deletionItems,
            uploadStates: uploadStates
        )
        return Self.groupByMonth(items: items, calendar: calendar)
    }

    // MARK: - Merge

    /// Stratégie de fusion :
    /// 1. Index les photos cloud par `localIdentifier` (ignorant la chaîne vide qui
    ///    signifie "cloud-only, pas d'ancrage local").
    /// 2. Pour chaque PHAsset local : émet un GalleryItem en croisant avec le cloud,
    ///    avec la file persistante (`BackupItem`), et avec l'état runtime éphémère.
    /// 3. Pour chaque cloud non rattaché à un asset local : émet un GalleryItem
    ///    `cloudOnly`.
    static func merge(
        localAssets: [LocalAssetSnapshot],
        cloudPhotos: [PhotoSnapshot],
        backupItems: [String: BackupItemSnapshot],
        deletionItems: [String: DeletionItemSnapshot],
        uploadStates: [String: UploadState]
    ) -> [GalleryItem] {
        let livePairs = LivePhotoPairing(photos: cloudPhotos)
        var cloudByLocalId: [String: PhotoSnapshot] = [:]
        for photo in cloudPhotos where !photo.localIdentifier.isEmpty && !livePairs.motionFileIds.contains(photo.fileId) {
            cloudByLocalId[photo.localIdentifier] = photo
        }
        var localIdsCovered = Set<String>()
        var items: [GalleryItem] = []
        items.reserveCapacity(localAssets.count + cloudPhotos.count)

        for asset in localAssets {
            localIdsCovered.insert(asset.localIdentifier)
            var cloud = cloudByLocalId[asset.localIdentifier]
            if cloud?.localModifiedAt != asset.modifiedAt { cloud?.backupComplete = false }
            // La suppression est indexée par `fileId`. Pour un asset local on ne
            // peut donc piloter le badge "deletion in progress" que si l'asset
            // a déjà été uploadé (cloud != nil). Cas typique : l'utilisateur
            // supprime une photo qui est aussi sur kDrive.
            let deletion = cloud.flatMap { deletionItems[$0.fileId] }
            let state = resolveState(
                localId: asset.localIdentifier,
                cloud: cloud,
                backupItem: backupItems[asset.localIdentifier],
                deletionItem: deletion,
                uploadStates: uploadStates
            )
            var item = GalleryItem(
                id: asset.localIdentifier,
                takenAt: asset.takenAt,
                isVideo: asset.isVideo,
                localAssetIdentifier: asset.localIdentifier,
                cloudFileId: cloud?.fileId,
                cloudDriveId: cloud?.driveId,
                syncState: state
            )
            item.thumbnailPack = cloud?.thumbnailPack; item.remoteRevision = cloud?.remoteRevision ?? ""
            items.append(item)
        }

        for cloud in cloudPhotos where !livePairs.motionFileIds.contains(cloud.fileId) {
            if !cloud.localIdentifier.isEmpty, localIdsCovered.contains(cloud.localIdentifier) {
                continue
            }
            let deletion = deletionItems[cloud.fileId]
            // Pour un cloud-only, on garde la priorité deletion → cloudOnly.
            let state: GalleryItemSyncState = {
                if let deletion {
                    return deletionState(from: deletion)
                }
                return .cloudOnly
            }()
            var item = GalleryItem(
                id: GalleryItem.cloudOnlyID(fileId: cloud.fileId),
                takenAt: cloud.takenAt,
                isVideo: cloud.isVideo,
                localAssetIdentifier: cloud.localIdentifier.isEmpty ? nil : cloud.localIdentifier,
                cloudFileId: cloud.fileId,
                cloudDriveId: cloud.driveId,
                syncState: state
            )
            item.thumbnailPack = cloud.thumbnailPack; item.remoteRevision = cloud.remoteRevision
            items.append(item)
        }

        // Tri global decroissant sur la date de prise de vue (cf. §6 AGENTS.md —
        // `takenAt` est la source de vérité, jamais `uploadedAt`).
        items.sort { $0.takenAt > $1.takenAt }
        return items
    }

    /// Conversion `DeletionItemState → GalleryItemSyncState`. Centralisée ici
    /// pour rester cohérente entre le path "local + cloud" et "cloudOnly".
    static func deletionState(from item: DeletionItemSnapshot) -> GalleryItemSyncState {
        switch item.state {
        case .queued: .deletionPending
        case .deleting: .deleting
        case .failedTransient:
            // Comme côté upload : silencieux côté UI tant qu'on n'a pas dépassé
            // le plafond. On retombe sur le badge "deletionPending" — visuel
            // "suppression en cours / en attente d'un retry", pas alarmiste.
            .deletionPending
        case .failedPermanent:
            .deletionFailed(reason: item.lastErrorReason)
        case .completed:
            // Ne devrait pas arriver — l'engine purge les `.completed` dans la
            // même transaction qu'il supprime le Photo. Si on tombe ici, on
            // ignore visuellement (retombe en .cloudOnly par le caller).
            .cloudOnly
        }
    }

    /// Priorités d'état (du plus prioritaire au plus faible) :
    /// 1. Spinner runtime (`UploadQueue`) — informe l'utilisateur que l'upload de
    ///    CETTE photo est actif en ce moment, indépendamment de ce que Realm a vu.
    /// 2. Présent côté cloud (`Photo.synced`) — `.synced`. Le cloud "gagne" sur la
    ///    file : si la photo est uploadée, son éventuel `BackupItem` orphelin
    ///    n'a plus à influencer l'UI.
    /// 3. État `BackupItem` (file persistante) — c'est la source de vérité pour
    ///    `.queued`, `.failedPermanent`. `.skipped` est traité comme `.localOnly`
    ///    visuellement (Phase 2 pourra introduire une icône dédiée).
    /// 4. Sinon — `.localOnly`. Cas typique : asset jamais réconcilié encore.
    static func resolveState(
        localId: String,
        cloud: PhotoSnapshot?,
        backupItem: BackupItemSnapshot?,
        deletionItem: DeletionItemSnapshot?,
        uploadStates: [String: UploadState]
    ) -> GalleryItemSyncState {
        // Suppression : priorité absolue. Si l'utilisateur a demandé à supprimer,
        // on n'affiche jamais "synced" ou "uploading" derrière — ce serait
        // mensonger et créerait un état perçu comme "annulé" alors que la
        // suppression est en cours.
        if let deletionItem {
            return deletionState(from: deletionItem)
        }
        if let runtime = uploadStates[localId] {
            switch runtime {
            case .uploading(let fraction): return .uploading(fraction: fraction)
            case .pending: return .pendingUpload
            case .failed, .completed: break // ignorés — la vérité vient de Realm
            }
        }
        if let cloud, cloud.syncStatus == .synced, cloud.backupComplete { return .synced }
        if let backupItem { return backupState(from: backupItem) }
        if let cloud, cloud.syncStatus == .error {
            return .uploadFailed(reason: "")
        }
        return .localOnly
    }

    private static func backupState(from backupItem: BackupItemSnapshot) -> GalleryItemSyncState {
        switch backupItem.state {
        case .queued: return .pendingUpload
        case .uploading: return .uploading(fraction: nil)
        case .completed: return .localOnly
        case .failedTransient:
            // Volontairement silencieux côté UI — l'item sera retenté
            // automatiquement après son `nextRetryAt`. Pas de badge orange
            // qui alarmerait l'utilisateur pour un flake passager (réseau,
            // 429, iCloud temporairement indispo). Le badge gris classique
            // reflète juste "pas encore sauvegardé", c'est la vérité.
            return .localOnly
        case .failedPermanent:
            return .uploadFailed(reason: backupItem.lastErrorReason)
        case .skipped:
            // Visuellement on garde le nuage barré gris — l'utilisateur a
            // choisi de ne pas backupper. Phase 2b ajoutera une variante visuelle.
            return .localOnly
        }
    }

    // MARK: - Group

    static func groupByMonth(items: [GalleryItem], calendar: Calendar) -> [GallerySection] {
        struct MonthBucket {
            let year: Int
            let month: Int
            var items: [GalleryItem]
        }
        var buckets: [String: MonthBucket] = [:]
        var order: [String] = []

        for item in items {
            let components = calendar.dateComponents([.year, .month], from: item.takenAt)
            guard let year = components.year, let month = components.month else { continue }
            let key = "\(year)-\(String(format: "%02d", month))"
            if buckets[key] == nil {
                buckets[key] = MonthBucket(year: year, month: month, items: [])
                order.append(key)
            }
            buckets[key]?.items.append(item)
        }
        return order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return GallerySection(year: bucket.year, month: bucket.month, items: bucket.items)
        }
    }
}
