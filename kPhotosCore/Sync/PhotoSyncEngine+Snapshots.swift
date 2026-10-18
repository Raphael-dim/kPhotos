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

extension PhotoSyncEngine {
    /// Capture dates come from PhotoKit for exported local assets.
    static func makeSnapshot(from dto: RemoteFileDTO, exported: ExportedAsset, driveId: Int) -> PhotoSnapshot {
        var snapshot = PhotoSnapshot(
            id: dto.id,
            driveId: driveId,
            localIdentifier: exported.localIdentifier,
            name: dto.name,
            takenAt: exported.takenAt,
            uploadedAt: Date(timeIntervalSince1970: TimeInterval(dto.createdAt)),
            mimeType: dto.mimeType,
            size: dto.size,
            isVideo: exported.isVideo,
            duration: 0,
            albumIds: [],
            syncStatus: .synced,
            isFavorite: false
        )
        snapshot.remoteRevision = dto.revision
        snapshot.captureDateSource = "photokit"
        snapshot.coordinate = exported.coordinate
        snapshot.locationSource = exported.coordinate == nil ? "" : "photokit"
        return snapshot
    }

    /// Construit un snapshot pour un fichier découvert en listant kDrive (pas de PHAsset local).
    /// `takenAt` utilise la chaîne de fallback `created_at → last_modified_at → added_at`
    /// pour éviter la date 1970 sur les fichiers uploadés depuis le web sans EXIF
    /// (cf. doc OpenAPI : `created_at` n'est rempli que si extractible des metadata).
    /// `uploadedAt` privilégie `added_at` (date d'upload immuable) plutôt que
    /// `last_modified_at` qui change à chaque modif du fichier.
    static func makeSnapshot(from dto: RemoteFileDTO, driveId: Int) -> PhotoSnapshot {
        let takenTimestamp = dto.bestTakenAt
        let uploadedTimestamp = dto.addedAt > 0 ? dto.addedAt : dto.lastModifiedAt
        var snapshot = PhotoSnapshot(
            id: dto.id,
            driveId: driveId,
            localIdentifier: "",
            name: dto.name,
            takenAt: Date(timeIntervalSince1970: TimeInterval(takenTimestamp)),
            uploadedAt: Date(timeIntervalSince1970: TimeInterval(uploadedTimestamp)),
            mimeType: dto.mimeType,
            size: dto.size,
            isVideo: dto.isVideoMedia,
            duration: 0,
            albumIds: [],
            syncStatus: .synced,
            isFavorite: false
        )
        snapshot.remoteRevision = dto.revision
        snapshot.captureDateSource = "kdrive"
        return snapshot
    }
}
