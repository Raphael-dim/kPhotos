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
import kPhotosCore

struct BackupActivityItem: Identifiable, Equatable {
    enum State: Equatable { case uploading(Double?), waiting, retrying, failed, skipped, unverified }
    let asset: LocalAssetSnapshot
    let state: State
    let reason: String
    let nextRetryAt: Date?
    var id: String { asset.localIdentifier }
}

struct BackupOverviewInput {
    let assets: [LocalAssetSnapshot]
    let photos: [PhotoSnapshot]
    let queue: [String: BackupItemSnapshot]
    let uploads: [String: UploadState]
    let driveId: Int
    let rootId: String
    let settings: SyncSettingsSnapshot
    let authorization: PhotoLibraryAuthorization
    let checked: Bool
    let running: Bool
    let error: String?
}

/// A completion claim requires verified originals in the selected drive and folder.
struct BackupOverview: Equatable {
    enum Phase: Equatable { case checking, saving, waiting, attention, upToDate, selectionComplete, accessRequired, empty }
    var phase: Phase = .checking
    var total = 0
    var verified = 0
    var items: [BackupActivityItem] = []
    var errorMessage: String?
    var lastBackupAt: Date?
    var mediaFilter: SyncMediaFilter = .both
    var automatic = false
    var limitedAccess = false

    var remaining: Int { total - verified }
    var active: [BackupActivityItem] { items.filter { if case .uploading = $0.state { return true }; return false } }
    var failed: Int { items.filter { $0.state == .failed || $0.state == .retrying }.count }
    var skipped: Int { items.filter { $0.state == .skipped }.count }
    var permanentFailures: Int { items.filter { $0.state == .failed }.count }
    var fraction: Double { total > 0 ? Double(verified) / Double(total) : 0 }
    var canStart: Bool { items.contains { $0.state == .waiting || $0.state == .unverified || $0.state == .retrying } }

    static func make(_ input: BackupOverviewInput) -> BackupOverview {
        let eligible = input.assets.filter { input.settings.mediaFilter.contains($0.isVideo ? .videos : .photos) }
        let localByID = Dictionary(eligible.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let verifiedPhotos = input.photos.filter { photo in
            guard let asset = localByID[photo.localIdentifier] else { return false }
            return photo.driveId == input.driveId && photo.libraryRootId == input.rootId
                && photo.isAvailable && photo.backupComplete && photo.localModifiedAt == asset.modifiedAt
        }
        let verifiedIDs = Set(verifiedPhotos.map(\.localIdentifier))
        var overview = BackupOverview()
        overview.total = eligible.count
        overview.mediaFilter = input.settings.mediaFilter
        overview.automatic = input.settings.isAutoSyncEnabled
        overview.limitedAccess = input.authorization == .limited
        overview.errorMessage = input.error
        overview.lastBackupAt = verifiedPhotos.map(\.uploadedAt).max()
        for asset in eligible {
            let queued = input.queue[asset.localIdentifier]
            let state: BackupActivityItem.State
            if case .uploading(let fraction) = input.uploads[asset.localIdentifier] {
                state = .uploading(fraction)
            } else if verifiedIDs.contains(asset.localIdentifier) {
                overview.verified += 1
                continue
            } else {
                switch queued?.state {
                case .failedPermanent: state = .failed
                case .failedTransient: state = .retrying
                case .skipped: state = .skipped
                case .completed: state = .unverified
                case .queued, .uploading, nil: state = .waiting
                }
            }
            overview.items.append(BackupActivityItem(
                asset: asset,
                state: state,
                reason: queued?.lastErrorReason ?? "",
                nextRetryAt: queued?.nextRetryAt
            ))
        }
        overview.items.sort { $0.asset.takenAt > $1.asset.takenAt }
        overview.phase = overview.resolvedPhase(input)
        return overview
    }

    private func resolvedPhase(_ input: BackupOverviewInput) -> Phase {
        if input.error != nil { return .attention }
        if input.authorization != .authorized && input.authorization != .limited { return .accessRequired }
        if input.running || !active.isEmpty { return .saving }
        if !input.checked { return .checking }
        if permanentFailures > 0 || skipped > 0 { return .attention }
        if total == 0 { return .empty }
        if remaining > 0 { return .waiting }
        if input.authorization == .limited || input.settings.mediaFilter != .both { return .selectionComplete }
        return .upToDate
    }
}
