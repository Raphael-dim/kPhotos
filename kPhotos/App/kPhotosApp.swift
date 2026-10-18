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

import kPhotosCore
import kPhotosCoreUI
import kPhotosFeatures
import SwiftUI

@main
struct KPhotosApp: App {
    @InjectService private var backgroundScheduler: BackgroundSyncScheduling
    @InjectService private var libraryPreparation: LibraryPreparationScheduling
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    private static var isUnitTestHost: Bool { NSClassFromString("XCTestCase") != nil }

    init() {
        FactoryService.registerAll()
        // Doit être appelé avant la fin de `application:didFinishLaunchingWithOptions`,
        // sinon `BGTaskScheduler.register` crash. SwiftUI App `init` est exécuté
        // dans cette fenêtre.
        if !Self.isUnitTestHost {
            backgroundScheduler.bootstrap()
            libraryPreparation.bootstrap()
        }
    }

    var body: some Scene {
        WindowGroup {
            if Self.isUnitTestHost {
                Color.clear // Unit tests must not start real cloud work from the host UI.
            } else {
                RootView()
                    .preferredColorScheme(theme.colorScheme)
                    .task(id: scenePhase) {
                        if scenePhase == .active {
                            await libraryPreparation.activate()
                        } else if scenePhase == .background {
                            await libraryPreparation.suspend()
                        }
                    }
            }
        }
        // À chaque passage en background, on (re-)soumet les `BGTaskRequest`.
        // Sans ça, après le tout premier slot BG consommé par iOS, on serait
        // à sec jusqu'au prochain changement de réglages. Re-submit est
        // idempotent : `BGTaskScheduler.submit` remplace une requête existante
        // au même identifier.
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                backgroundScheduler.scheduleNextRefreshIfNeeded()
            }
        }
    }
}
