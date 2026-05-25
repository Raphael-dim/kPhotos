/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

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
import kPhotosResources
import SwiftUI

public struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showFolderPicker = false
    @State private var showSignOutConfirmation = false
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    private let onSignedOut: () -> Void

    public init(onSignedOut: @escaping () -> Void) {
        self.onSignedOut = onSignedOut
    }

    public var body: some View {
        NavigationStack {
            List {
                drivesSection
                folderSection
                appearanceSection
                accountSection
            }
            .navigationTitle(L10n.Settings.title)
            .task { await viewModel.loadDrives() }
            .refreshable { await viewModel.loadDrives() }
            .overlay {
                if viewModel.isLoading && viewModel.drives.isEmpty {
                    ProgressView()
                }
            }
            .onChange(of: viewModel.didSignOut) { signedOut in
                if signedOut { onSignedOut() }
            }
            .alert(L10n.Settings.signOutConfirmTitle, isPresented: $showSignOutConfirmation) {
                Button(L10n.Settings.signOutConfirmAction, role: .destructive) {
                    Task { await viewModel.signOut() }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Settings.signOutConfirmMessage)
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { folder in
                    let name = folder.name.isEmpty ? SyncSettingsSnapshot.defaultRootFolderName : folder.name
                    Task { await viewModel.setRootFolder(id: folder.folderId, name: name) }
                }
            }
        }
    }

    private var drivesSection: some View {
        Section {
            if viewModel.drives.isEmpty && !viewModel.isLoading {
                Text(L10n.Settings.drivesEmpty)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.drives) { drive in
                Button {
                    Task { await viewModel.selectDrive(id: drive.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drive.name)
                                .foregroundStyle(.primary)
                            Text(Self.formatStorage(used: drive.usedSize, total: drive.totalSize))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if drive.isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(L10n.Settings.storage)
        }
    }

    private var folderSection: some View {
        Section {
            Button {
                showFolderPicker = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.folderHeader)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(viewModel.rootFolderName.isEmpty ? L10n.Settings.folderPlaceholder : viewModel.rootFolderName)
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                }
            }
        } footer: {
            Text(L10n.Settings.folderFooter)
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(L10n.Settings.appearance, selection: $theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(L10n.Settings.appearance)
        }
    }

    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                showSignOutConfirmation = true
            } label: {
                Text(L10n.Settings.signOut)
            }
        } header: {
            Text(L10n.Settings.account)
        }
    }

    private static func formatStorage(used: Int64, total: Int64) -> String {
        guard total > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: used)) / \(formatter.string(fromByteCount: total))"
    }
}
