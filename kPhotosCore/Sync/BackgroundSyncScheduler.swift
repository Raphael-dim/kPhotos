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
import Combine
import Foundation

/// Identifiants déclarés dans Info.plist sous `BGTaskSchedulerPermittedIdentifiers`.
public enum BackgroundSyncIdentifiers {
    /// `BGAppRefreshTask` — court (~30s), fréquent. Drain de 5-10 items pour
    /// garder la file fraîche entre deux ouvertures de l'app.
    public static let appRefresh = "app.kphotos.sync.refresh"
    /// `BGProcessingTask` — plusieurs minutes, opportuniste. Drain d'un gros
    /// backlog quand iOS juge le moment opportun (souvent la nuit en charge +
    /// Wi-Fi). On exige `requiresNetworkConnectivity` pour ne pas être réveillés
    /// hors-ligne ; on n'exige PAS la charge pour rester déclenchable en journée.
    public static let processing = "app.kphotos.sync.processing"
}

public protocol BackgroundSyncScheduling: AnyObject {
    /// À appeler une fois au lancement de l'app (`KPhotosApp.init`).
    /// Enregistre les handlers BGTask et observe les réglages utilisateur pour
    /// planifier ou annuler en conséquence.
    func bootstrap()

    /// Planifie la prochaine exécution des deux tasks BG si l'utilisateur a
    /// activé la sync auto. No-op sinon. Idempotent — `BGTaskScheduler.submit`
    /// remplace une éventuelle requête existante avec le même identifier.
    func scheduleNextRefreshIfNeeded()
}

public final class BackgroundSyncScheduler: BackgroundSyncScheduling {
    private let settings: SyncSettingsReading
    private let drives: DriveManaging
    private let sync: PhotoSyncing
    private let reachability: NetworkReachable

    /// Earliest-begin de la `appRefresh` (BGAppRefreshTask). 1h — laisse iOS
    /// choisir le moment réel selon ses heuristiques. iOS impose un minimum
    /// d'au moins 15min en pratique.
    private let refreshInterval: TimeInterval
    /// Earliest-begin de la `processing` (BGProcessingTask). 2h — plus long
    /// que `appRefresh` parce que cette task est destinée à drainer un gros
    /// backlog quand iOS trouve un slot favorable, pas à être réactive.
    private let processingInterval: TimeInterval

    /// Plafonds par session BG. `appRefresh` est court → cap bas. `processing`
    /// peut tourner plusieurs minutes → cap plus haut, et la cancellation Swift
    /// arrête proprement à l'`expirationHandler` (cf. `runFullSync` qui await
    /// entre chaque item).
    private let appRefreshBudget: Int = 10
    private let processingBudget: Int = 100

    private var cancellable: AnyCancellable?

    public init(
        settings: SyncSettingsReading,
        drives: DriveManaging,
        sync: PhotoSyncing,
        reachability: NetworkReachable,
        refreshInterval: TimeInterval = 60 * 60,
        processingInterval: TimeInterval = 2 * 60 * 60
    ) {
        self.settings = settings
        self.drives = drives
        self.sync = sync
        self.reachability = reachability
        self.refreshInterval = refreshInterval
        self.processingInterval = processingInterval
    }

    public func bootstrap() {
        // Register doit être appelé AVANT la fin de `application:didFinishLaunching`,
        // d'où l'invocation depuis `KPhotosApp.init`. Sinon crash au prochain run.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSyncIdentifiers.appRefresh,
            using: nil
        ) { [weak self] task in
            guard let self, let task = task as? BGAppRefreshTask else { return }
            handle(task: task, budget: appRefreshBudget)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSyncIdentifiers.processing,
            using: nil
        ) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else { return }
            handle(task: task, budget: processingBudget)
        }

        // Réagit aux changements de réglages : si l'utilisateur active l'auto-sync
        // on planifie, s'il la désactive on annule. Le first publish (CurrentValue)
        // déclenche aussi la première planification au lancement.
        cancellable = settings.publisher.sink { [weak self] snapshot in
            guard let self else { return }
            if snapshot.isAutoSyncEnabled {
                scheduleNextRefreshIfNeeded()
            } else {
                BGTaskScheduler.shared.cancel(
                    taskRequestWithIdentifier:
                    BackgroundSyncIdentifiers.appRefresh
                )
                BGTaskScheduler.shared.cancel(
                    taskRequestWithIdentifier:
                    BackgroundSyncIdentifiers.processing
                )
            }
        }
    }

    public func scheduleNextRefreshIfNeeded() {
        guard let snapshot = try? settings.current(), snapshot.isAutoSyncEnabled else { return }

        let refreshRequest = BGAppRefreshTaskRequest(identifier: BackgroundSyncIdentifiers.appRefresh)
        refreshRequest.earliestBeginDate = Date().addingTimeInterval(refreshInterval)

        let processingRequest = BGProcessingTaskRequest(identifier: BackgroundSyncIdentifiers.processing)
        processingRequest.earliestBeginDate = Date().addingTimeInterval(processingInterval)
        processingRequest.requiresNetworkConnectivity = true
        // On n'exige PAS `requiresExternalPower` — l'utilisateur ne s'attend pas
        // à devoir brancher le téléphone pour que ses photos remontent. iOS
        // reste libre de privilégier les moments en charge selon ses heuristiques.
        processingRequest.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
            try BGTaskScheduler.shared.submit(processingRequest)
        } catch {
            // Pas de Sentry ici (interdit côté Core) — silencieux, le scheduler
            // sera retenté à la prochaine modification de settings, à l'entrée
            // en background, ou à la fin d'un BG handler (qui re-schedule).
        }
    }

    // MARK: - Task handler

    /// Stratégie pour les deux types de tasks :
    /// 1. Replanifier *avant* de bosser — sinon si on dépasse, on perd le slot suivant.
    /// 2. Bailout immédiat si la politique réseau ne valide pas l'état courant.
    /// 3. Sync limitée à `budget` items. La cancellation Swift via
    ///    `expirationHandler → work.cancel()` arrête proprement le drainage
    ///    entre deux items grâce aux `await` dans `runFullSync`.
    private func handle(task: BGTask, budget: Int) {
        scheduleNextRefreshIfNeeded()

        guard let snapshot = try? settings.current(), snapshot.isAutoSyncEnabled else {
            task.setTaskCompleted(success: true)
            return
        }
        guard reachability.allowsSync(under: snapshot.networkPolicy) else {
            task.setTaskCompleted(success: true)
            return
        }

        let work = Task {
            do {
                guard let drive = try drives.selectedDrive() else {
                    task.setTaskCompleted(success: true)
                    return
                }
                let folderId = try await drives.ensureRootFolder(folderName: snapshot.rootFolderName)
                try await sync.runFullSync(
                    driveId: drive.id,
                    folderId: folderId,
                    maxItems: budget,
                    onProgress: { _ in }
                )
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                // L'OS a coupé via `expirationHandler` — les items déjà traités
                // sont persistés via `BackupItem` côté Realm. On déclare success
                // pour ne pas pénaliser nos prochains slots BG (Apple punit les
                // tasks qui rapportent `success: false`).
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = { work.cancel() }
    }
}
