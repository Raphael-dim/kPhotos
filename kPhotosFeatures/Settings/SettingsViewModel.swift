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

import Combine
import Foundation
import kPhotosCore

@MainActor
public final class SettingsViewModel: ObservableObject {
    public struct DriveItem: Identifiable, Equatable {
        public let id: Int
        public let name: String
        public let usedSize: Int64
        public let totalSize: Int64
        public let isSelected: Bool
    }

    @Published public private(set) var drives: [DriveItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var didSignOut = false

    /// Édité directement par la `TextField` Settings, persisté à la perte de focus
    /// (cf. `commitRootFolderName`). On garde un état local pour pouvoir afficher
    /// la saisie en cours sans round-trip Realm.
    @Published public var rootFolderName: String = SyncSettingsSnapshot.defaultRootFolderName

    @InjectService private var driveManager: DriveManaging
    @InjectService private var auth: AuthService
    @InjectService private var settingsReader: SyncSettingsReading
    @InjectService private var settingsWriter: SyncSettingsWriting

    private var cancellables: Set<AnyCancellable> = []
    private var lastPersistedFolderName: String = SyncSettingsSnapshot.defaultRootFolderName

    public init() {
        settingsReader.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.lastPersistedFolderName = snapshot.rootFolderName
                if rootFolderName != snapshot.rootFolderName {
                    self.rootFolderName = snapshot.rootFolderName
                }
            }
            .store(in: &cancellables)
    }

    /// Persiste le nom de dossier et invalide les `rootFolderId` en cache pour que
    /// le prochain `ensureRootFolder` recrée/retrouve le bon dossier côté serveur.
    public func commitRootFolderName() async {
        let trimmed = rootFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? SyncSettingsSnapshot.defaultRootFolderName : trimmed
        if resolved != rootFolderName { rootFolderName = resolved }
        guard resolved != lastPersistedFolderName else { return }
        do {
            try await settingsWriter.update { snapshot in
                snapshot.rootFolderName = resolved
            }
            try await driveManager.resetCachedRootFolders()
            lastPersistedFolderName = resolved
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Définit le dossier racine à partir d'une sélection du FolderPicker
    public func setRootFolder(id: String, name: String) async {
        rootFolderName = name
        lastPersistedFolderName = name
        do {
            try await settingsWriter.update { snapshot in
                snapshot.rootFolderName = name
            }
            try await driveManager.resetCachedRootFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadDrives() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await driveManager.refreshFromServer()
            let selectedId = (try? driveManager.selectedDrive())?.id
            drives = fetched.map { drive in
                DriveItem(
                    id: drive.id,
                    name: drive.name,
                    usedSize: drive.usedSize,
                    totalSize: drive.size,
                    isSelected: drive.id == selectedId
                )
            }
            if selectedId == nil, let first = fetched.first {
                try await driveManager.selectDrive(id: first.id)
                await loadDrives()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectDrive(id: Int) async {
        do {
            try await driveManager.selectDrive(id: id)
            await loadDrives()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signOut() async {
        do {
            try await auth.signOut()
            didSignOut = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
