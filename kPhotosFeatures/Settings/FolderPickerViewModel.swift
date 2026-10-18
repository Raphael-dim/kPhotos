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

@MainActor
public final class FolderPickerViewModel: ObservableObject {
    public struct FolderNode: Identifiable, Equatable {
        public let folderId: String
        public let name: String
        public let isRoot: Bool

        public var id: String { folderId }

        public init(folderId: String, name: String, isRoot: Bool = false) {
            self.folderId = folderId
            self.name = name
            self.isRoot = isRoot
        }

        public var displayName: String {
            if isRoot { return "kDrive" }
            return name
        }
    }

    @Published public private(set) var currentFolder: FolderNode
    @Published public private(set) var subfolders: [FolderNode] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public var newFolderName = ""
    @Published public var showCreateFolder = false

    public private(set) var breadcrumbs: [FolderNode] = []
    private var driveId: Int = 1
    private var privateSpaceId: String = ""

    @InjectService private var api: PhotoApiFetching
    @InjectService private var driveManager: DriveManaging

    public init() {
        self.currentFolder = FolderNode(folderId: "1", name: "", isRoot: true)
    }

    public func loadInitial() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let selectedDrive = try driveManager.selectedDrive() else {
                errorMessage = "No drive selected"
                return
            }
            driveId = selectedDrive.id
            privateSpaceId = try await driveManager.ensurePrivateSpace()
            currentFolder = FolderNode(folderId: privateSpaceId, name: selectedDrive.name, isRoot: true)
            await loadFolders(folderId: privateSpaceId, keepCurrent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func loadFolders(folderId: String, keepCurrent: Bool = false) async {
        if !keepCurrent { isLoading = true }
        defer { if !keepCurrent { isLoading = false } }
        do {
            let page = try await api.listFolder(driveId: driveId, folderId: folderId, cursor: nil, limit: 100)
            let folders = page.items.filter(\.isDirectory)
            if !keepCurrent {
                currentFolder = FolderNode(
                    folderId: folderId,
                    name: currentFolder.name,
                    isRoot: folderId == privateSpaceId
                )
            }
            subfolders = folders.map { file in
                FolderNode(folderId: file.id, name: file.name)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func navigateToFolder(_ folder: FolderNode) async {
        breadcrumbs.append(currentFolder)
        currentFolder = folder
        await loadFolders(folderId: folder.folderId)
    }

    public func navigateBack() async {
        guard !breadcrumbs.isEmpty else { return }
        currentFolder = breadcrumbs.removeLast()
        await loadFolders(folderId: currentFolder.folderId)
    }

    public func createNewFolder() async {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Folder name cannot be empty"
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let newFolder = try await api.createDirectory(
                driveId: driveId,
                name: trimmed,
                parentId: currentFolder.folderId
            )
            newFolderName = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showCreateFolder = false
            }
            subfolders.append(FolderNode(folderId: newFolder.id, name: newFolder.name))
            subfolders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func getFullPath() -> String {
        let trail = breadcrumbs.map(\.displayName) + [currentFolder.displayName]
        return trail.joined(separator: " / ")
    }
}
