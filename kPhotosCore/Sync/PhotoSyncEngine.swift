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

public struct SyncProgress: Equatable {
    public let completed: Int
    public let total: Int
    public let lastUploadedFileName: String?
    public let processed: Int

    public init(completed: Int, total: Int, lastUploadedFileName: String?, processed: Int? = nil) {
        self.completed = completed
        self.total = total
        self.lastUploadedFileName = lastUploadedFileName
        self.processed = processed ?? completed
    }

    public var fraction: Double { total == 0 ? 0 : Double(processed) / Double(total) }
}

/// Erreur métier remontée quand la sync ne peut pas démarrer pour des raisons
/// utilisateur (réseau, settings) plutôt que techniques.
public enum SyncPolicyError: Error, LocalizedError, Equatable {
    case networkNotAllowed(current: NetworkKind, policy: SyncNetworkPolicy)
    case nothingToSync

    public var errorDescription: String? {
        switch self {
        case .networkNotAllowed(let current, _):
            switch current {
            case .offline: "Aucune connexion réseau."
            case .cellular: "Sync via données cellulaires désactivée."
            case .wifi, .other: "Sync via Wi-Fi désactivée."
            }
        case .nothingToSync: "Aucune photo à synchroniser."
        }
    }
}

public protocol PhotoSyncing: AnyObject {
    /// Liste un dossier kDrive et met à jour l'index Realm local.
    func refreshFolder(driveId: Int, folderId: String) async throws

    /// Réconcilie la file persistante avec la photothèque iOS :
    /// enqueue dans `BackupItem` chaque asset PhotoKit qui n'est ni déjà connu de la
    /// file (quel que soit son état) ni déjà synced côté cloud.
    /// Idempotent — peut être appelée à chaque ouverture de l'app sans risque de
    /// doublon (la clé primaire `localIdentifier` + la transaction de réconciliation
    /// garantissent l'absence de re-insertion).
    /// Honore `SyncSettings.mediaFilter` : un asset filtré ne rentre pas en file.
    func reconcile() async throws

    /// Draine la file `BackupItem.queued` (triée newest-first) jusqu'à `maxItems`.
    /// `nil` = drainer toute la file en une session. Séquentiel — un upload à la
    /// fois pour ne pas saturer l'API kDrive (cf. docs/api/infomaniak_openapi.json :
    /// `performWithRetry` gère 429/5xx avec backoff exponentiel).
    /// `onProgress` est appelé sur le main actor à chaque item terminé.
    func runFullSync(
        driveId: Int,
        folderId: String,
        maxItems: Int?,
        onProgress: @MainActor @escaping (SyncProgress) -> Void
    ) async throws
}

public final class PhotoSyncEngine: PhotoSyncing {
    private let api: PhotoApiFetching
    private let drives: DriveManaging
    private let photoReader: PhotoReading
    private let photoWriter: PhotoWriting
    private let backupQueueReader: BackupQueueReading
    private let backupQueueWriter: BackupQueueWriting
    private let assetReader: PHAssetReading
    private let exporter: PHAssetExporting
    private let settings: SyncSettingsReading
    private let reachability: NetworkReachable
    private let uploadQueue: UploadQueueWriting
    private let fileManager: FileManager

    public init(
        api: PhotoApiFetching,
        drives: DriveManaging,
        photoReader: PhotoReading,
        photoWriter: PhotoWriting,
        backupQueueReader: BackupQueueReading,
        backupQueueWriter: BackupQueueWriting,
        assetReader: PHAssetReading,
        exporter: PHAssetExporting,
        settings: SyncSettingsReading,
        reachability: NetworkReachable,
        uploadQueue: UploadQueueWriting,
        fileManager: FileManager = .default
    ) {
        self.api = api
        self.drives = drives
        self.photoReader = photoReader
        self.photoWriter = photoWriter
        self.backupQueueReader = backupQueueReader
        self.backupQueueWriter = backupQueueWriter
        self.assetReader = assetReader
        self.exporter = exporter
        self.settings = settings
        self.reachability = reachability
        self.uploadQueue = uploadQueue
        self.fileManager = fileManager
    }

    public func refreshFolder(driveId: Int, folderId: String) async throws {
        let snapshots = try await LibraryScanner(api: api).scan(driveId: driveId, rootId: folderId)
        try Task.checkCancellation()
        try await photoWriter.commitListing(
            snapshots.photos,
            driveId: driveId,
            folderId: folderId,
            fileIds: snapshots.fileIds,
            revisions: snapshots.revisions
        )
        LibraryRefreshSchedule().markSuccess(driveId: driveId, rootId: folderId)
    }

    public func reconcile() async throws {
        let snapshot = try settings.current()
        let localAssets = await assetReader.fetchAssetSnapshots(filter: snapshot.mediaFilter)

        // Couverture = assets dont on sait déjà quoi faire :
        // - déjà uploadés côté cloud (Realm `Photo` avec localIdentifier renseigné)
        // - déjà connus de la file persistante (peu importe l'état : queued, uploading,
        //   completed, failedPermanent, skipped). Ne pas re-insérer un item `.skipped`
        //   automatiquement — l'utilisateur l'a explicitement écarté.
        guard let drive = try drives.selectedDrive() else { return }
        let localDates = Dictionary(uniqueKeysWithValues: localAssets.map { ($0.localIdentifier, $0.modifiedAt) })
        let syncedIdentifiers: Set<String> = try Set(
            (photoReader.allPhotos())
                .filter { $0.driveId == drive.id && $0.libraryRootId == drive.rootFolderId
                    && $0.isAvailable && $0.backupComplete && $0.localModifiedAt == localDates[$0.localIdentifier]
                }
                .map(\.localIdentifier)
                .filter { !$0.isEmpty }
        )
        try await backupQueueWriter.reconcile(localAssets: localAssets, syncedIdentifiers: syncedIdentifiers)
    }

    public func runFullSync(
        driveId: Int,
        folderId: String,
        maxItems: Int?,
        onProgress: @MainActor @escaping (SyncProgress) -> Void
    ) async throws {
        guard await BackupRunLock.shared.acquire() else { throw BackupSafetyError.busy }
        do {
            try await performFullSync(driveId: driveId, folderId: folderId, maxItems: maxItems, onProgress: onProgress)
            await BackupRunLock.shared.release()
        } catch {
            await BackupRunLock.shared.release()
            throw error
        }
    }

    private func performFullSync(
        driveId: Int,
        folderId: String,
        maxItems: Int?,
        onProgress: @MainActor @escaping (SyncProgress) -> Void
    ) async throws {
        try validateNetworkPolicy()

        // Une lecture récursive de toute la bibliothèque cloud pouvait prendre
        // des minutes avant le premier upload. ResourceBackup vérifie chaque
        // destination et ses octets avant de réutiliser ou d'envoyer un fichier.
        try await reconcile()

        // Sweep des items bloqués en `.uploading` — crash, kill OS, BGTask
        // expirée. Sans ça, ils resteraient orphelins (non-pickable par
        // `nextProcessable`). Idempotent, coûte une transaction Realm.
        try await backupQueueWriter.resetOrphanedUploads()

        uploadQueue.beginScope(driveId: driveId, rootId: folderId)
        let processable = try backupQueueReader.nextProcessable(now: Date(), limit: maxItems)
        let resourceBackup = ResourceBackup(api: api)
        var verifiedCount = 0
        var processedCount = 0
        await onProgress(SyncProgress(completed: 0, total: processable.count, lastUploadedFileName: nil))
        if processable.isEmpty { return }

        for item in processable {
            // Bail out propre si la `Task` a été cancellée (typiquement
            // `BGProcessingTask.expirationHandler`). Les items déjà traités
            // sont persistés dans BackupItem.
            try Task.checkCancellation()

            // Le badge spinner sur la tuile est piloté par UploadQueue (transient).
            // L'état persistant `.uploading` côté BackupItem trace les retries.
            uploadQueue.mark(localIdentifier: item.localIdentifier, state: .uploading(fraction: nil))
            try await backupQueueWriter.markUploading(localIdentifier: item.localIdentifier)

            let progressedName: String?
            do {
                let result = try await uploadOne(
                    item: item,
                    driveId: driveId,
                    folderId: folderId,
                    backup: resourceBackup
                )
                try await backupQueueWriter.markCompleted(localIdentifier: item.localIdentifier)
                verifiedCount += 1
                uploadQueue.mark(localIdentifier: item.localIdentifier, state: .completed)
                progressedName = result.name
            } catch is CancellationError {
                // OS a coupé l'upload (BGTask expirée). On laisse l'item dans
                // `.uploading` — `resetOrphanedUploads()` au prochain runFullSync
                // le repositionnera en `.queued`. On re-throw pour sortir
                // proprement de la boucle ; le caller (handle BGTask) capture
                // `CancellationError` et déclare success pour ne pas pénaliser
                // nos prochains slots BG.
                uploadQueue.mark(localIdentifier: item.localIdentifier, state: .completed)
                throw CancellationError()
            } catch {
                // Classification transient vs permanent. Le classifier reçoit le
                // `attemptCount` POST-incrément (cf. `markUploading` qui vient de
                // l'incrémenter) — utile pour appliquer le bon palier de backoff
                // ou escalader en `.failedPermanent` après le plafond.
                let decision = BackupRetryClassifier.classify(
                    error: error,
                    attemptCount: item.attemptCount + 1
                )
                let reason = Self.userFacingReason(from: error)
                switch decision {
                case .transient(let retryAfter):
                    let nextAt = Date().addingTimeInterval(retryAfter)
                    try await backupQueueWriter.markFailedTransient(
                        localIdentifier: item.localIdentifier,
                        reason: reason,
                        nextRetryAt: nextAt
                    )
                case .permanent:
                    try await backupQueueWriter.markFailedPermanent(
                        localIdentifier: item.localIdentifier, reason: reason
                    )
                }
                uploadQueue.mark(localIdentifier: item.localIdentifier, state: .completed)
                progressedName = nil
            }

            processedCount += 1
            await onProgress(SyncProgress(
                completed: verifiedCount,
                total: processable.count,
                lastUploadedFileName: progressedName,
                processed: processedCount
            ))
        }

        // Nettoie l'état runtime — le rebuild de galerie relira BackupItem comme
        // source de vérité, sans transition `.uploading` résiduelle.
        uploadQueue.clearCompleted()
    }

    // MARK: - Error formatting

    /// Convertit l'erreur d'upload en message lisible par l'utilisateur final.
    /// `ExportError` conforme déjà à `LocalizedError` — `localizedDescription` rend
    /// le message FR documenté côté enum. Pour les autres erreurs (réseau, API), on
    /// retombe sur la description native, qui reste plus parlante que `String(describing:)`.
    static func userFacingReason(from error: Error) -> String {
        if let exportError = error as? ExportError {
            return exportError.errorDescription ?? exportError.localizedDescription
        }
        if let apiError = error as? PhotoAPIError {
            return apiError.errorDescription ?? apiError.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: - Single upload

    /// Charge le `PHAsset` depuis PhotoKit, l'exporte, upload via API, persiste
    /// le snapshot cloud. `clientToken` vient de `BackupItem` → idempotent côté
    /// serveur même si un retry rejoue la requête après réponse perdue.
    private func uploadOne(
        item: BackupItemSnapshot,
        driveId: Int,
        folderId: String,
        backup: ResourceBackup
    ) async throws -> PhotoSnapshot {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { throw ExportError.noResource }
        let exported = try await exporter.export(asset)
        let manifestURL = exported.fileURL.deletingLastPathComponent().appendingPathComponent(exported.fileName + ".kphotos.json")
        defer { cleanupExport(exported, manifestURL: manifestURL) }
        let destination = try await backup.destination(driveId: driveId, rootId: folderId, date: exported.takenAt)
        let candidates = try photoReader.allPhotos().filter {
            $0.driveId == driveId && $0.libraryRootId == folderId && $0.isAvailable
        }
        let primary = ExportedResource(
            fileURL: exported.fileURL,
            fileName: exported.fileName,
            mimeType: exported.mimeType,
            resourceType: 0,
            originalFilename: exported.fileName
        )
        var verified: [(RemoteFileDTO, String)] = []
        for resource in [primary] + exported.additionalResources {
            try Task.checkCancellation()
            let result = try await backup.findOrUpload(
                resource: resource,
                identity: .init(
                    date: exported.takenAt,
                    token: item.clientToken,
                    localIdentifier: exported.localIdentifier
                ),
                driveId: driveId,
                folderId: destination,
                candidates: candidates
            )
            verified.append(result)
        }
        guard let (dto, hash) = verified.first else { throw BackupSafetyError.incomplete }
        let manifestResult = try await uploadManifest(
            exported: exported,
            verified: verified,
            driveId: driveId,
            destination: destination,
            token: item.clientToken,
            backup: backup
        )
        var snapshot = Self.makeSnapshot(
            from: dto,
            exported: exported,
            driveId: driveId
        )
        snapshot.libraryRootId = folderId
        snapshot.contentSHA256 = hash
        snapshot.resourceFileIds = verified.map(\.0.id) + [manifestResult.0.id]
        snapshot.backupComplete = true
        snapshot.localModifiedAt = asset.modificationDate
        snapshot.resourceRevisions = Dictionary(
            (verified + [manifestResult]).map { ($0.0.id, $0.0.revision) },
            uniquingKeysWith: { _, last in last }
        )
        try await photoWriter.upsert(snapshot)
        return snapshot
    }

    // MARK: - Manifest verification

    private func uploadManifest(
        exported: ExportedAsset,
        verified: [(RemoteFileDTO, String)],
        driveId: Int,
        destination: String,
        token: String,
        backup: ResourceBackup
    ) async throws -> (RemoteFileDTO, String) {
        let manifestURL = exported.fileURL.deletingLastPathComponent().appendingPathComponent(exported.fileName + ".kphotos.json")
        guard let metadata = exported.metadata,
              var manifest = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            throw BackupSafetyError.incomplete
        }
        manifest["verifiedFiles"] = verified.map { [
            "driveId": driveId,
            "fileId": $0.0.id,
            "name": $0.0.name,
            "sha256": $0.1
        ] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        let sidecar = ExportedResource(
            fileURL: manifestURL,
            fileName: manifestURL.lastPathComponent,
            mimeType: "application/json",
            resourceType: -1,
            originalFilename: manifestURL.lastPathComponent
        )
        return try await backup.findOrUpload(
            resource: sidecar,
            identity: .init(
                date: exported.takenAt,
                token: token,
                localIdentifier: exported.localIdentifier
            ),
            driveId: driveId,
            folderId: destination,
            candidates: []
        )
    }

    private func validateNetworkPolicy() throws {
        let snapshot = try settings.current()

        // Validation aux frontières (§Fail fast AGENTS.md).
        guard reachability.allowsSync(under: snapshot.networkPolicy) else {
            throw SyncPolicyError.networkNotAllowed(
                current: reachability.currentKind(),
                policy: snapshot.networkPolicy
            )
        }
    }

    private func cleanupExport(_ exported: ExportedAsset, manifestURL: URL) {
        for url in [exported.fileURL, manifestURL] + exported.additionalResources.map(\.fileURL) {
            try? fileManager.removeItem(at: url) // Files owned by this temporary export only.
        }
        let directory = exported.fileURL.deletingLastPathComponent()
        if directory.deletingLastPathComponent().lastPathComponent == "kPhotosExports" {
            try? fileManager.removeItem(at: directory)
        }
    }
}
