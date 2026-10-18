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

import BackgroundTasks
import Foundation

public protocol LibraryPreparationScheduling: AnyObject {
    func bootstrap()
    func activate() async
    func suspend() async
}

/// OS lifecycle integration is separate from the resumable metadata worker and from photo uploads.
public final class LibraryPreparationScheduler: LibraryPreparationScheduling {
    public static let identifier = "app.kphotos.library.processing"
    private let drives: DriveManaging
    private let indexer: EmbeddedMetadataIndexing
    private let preparedIndex: PreparedMediaIndexSyncing

    public init(drives: DriveManaging, indexer: EmbeddedMetadataIndexing, preparedIndex: PreparedMediaIndexSyncing) {
        self.drives = drives; self.indexer = indexer; self.preparedIndex = preparedIndex
    }

    public func bootstrap() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { [weak self] task in
            guard let self else { task.setTaskCompleted(success: false); return }
            schedule()
            let work = Task {
                do {
                    guard let drive = try self.drives.selectedDrive(), !drive.rootFolderId.isEmpty else {
                        task.setTaskCompleted(success: true); return
                    }
                    _ = try await self.indexer.runBatch(driveId: drive.id, rootId: drive.rootFolderId, limit: 100)
                    task.setTaskCompleted(success: !Task.isCancelled)
                } catch { task.setTaskCompleted(success: false) }
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    public func activate() async {
        do {
            guard let drive = try drives.selectedDrive(), !drive.rootFolderId.isEmpty else { return }
            do {
                try await preparedIndex.refresh(driveId: drive.id, rootId: drive.rootFolderId)
            } catch {
                // Optional cloud cache failure never prevents local preparation.
            }
            try Task.checkCancellation()
            // The selection might have changed while the remote cache was read.
            guard let current = try drives.selectedDrive(), current.id == drive.id,
                  current.rootFolderId == drive.rootFolderId else { return }
            await indexer.start(driveId: drive.id, rootId: drive.rootFolderId)
        } catch { /* An unavailable database/selection cannot be prepared; existing source files stay untouched. */ }
    }

    public func suspend() async {
        await indexer.suspend()
        schedule()
    }

    private func schedule() {
        guard let drive = try? drives.selectedDrive(), !drive.rootFolderId.isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The OS may reject scheduling; foreground activation still resumes the durable queue.
        }
    }
}
