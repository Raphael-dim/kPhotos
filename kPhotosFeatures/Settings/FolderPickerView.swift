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
 */

import kPhotosResources
import SwiftUI

public struct FolderPickerView: View {
    @StateObject private var viewModel = FolderPickerViewModel()
    public let onFolderSelected: (FolderPickerViewModel.FolderNode) -> Void
    @Environment(\.dismiss) var dismiss

    public init(onFolderSelected: @escaping (FolderPickerViewModel.FolderNode) -> Void) {
        self.onFolderSelected = onFolderSelected
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                List {
                    // Bouton pour sélectionner le dossier actuel
                    // La racine du Private Space n'est pas un emplacement de stockage valide :
                    // on force l'utilisateur à descendre dans un sous-dossier.
                    Section {
                        Button {
                            onFolderSelected(viewModel.currentFolder)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.FolderPicker.selectThisFolder)
                                        .foregroundStyle(viewModel.currentFolder.isRoot ? .secondary : .primary)
                                    if viewModel.currentFolder.isRoot {
                                        Text(L10n.FolderPicker.rootNotSelectable)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(viewModel.getFullPath())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(viewModel.currentFolder.isRoot ? Color.secondary : Color.accentColor)
                            }
                        }
                        .disabled(viewModel.currentFolder.isRoot)
                    }

                    // Bouton créer un nouveau dossier
                    Section {
                        Button {
                            viewModel.showCreateFolder = true
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundStyle(.tint)
                                Text(L10n.FolderPicker.createNewFolder)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }

                    // Liste des sous-dossiers
                    if !viewModel.subfolders.isEmpty {
                        Section(L10n.FolderPicker.subfolders) {
                            ForEach(viewModel.subfolders) { folder in
                                Button {
                                    Task { await viewModel.navigateToFolder(folder) }
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.blue)
                                        Text(folder.displayName)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if viewModel.subfolders.isEmpty && !viewModel.isLoading {
                        Section {
                            Text(L10n.FolderPicker.noSubfolders)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if viewModel.isLoading {
                    ProgressView()
                }
            }
            .navigationTitle(viewModel.currentFolder.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.breadcrumbs.isEmpty {
                        Button(L10n.Common.cancel) { dismiss() }
                    } else {
                        Button {
                            Task { await viewModel.navigateBack() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(L10n.FolderPicker.back)
                            }
                        }
                    }
                }
            }
            .task { await viewModel.loadInitial() }
            .sheet(isPresented: $viewModel.showCreateFolder) {
                NavigationStack {
                    Form {
                        TextField(L10n.FolderPicker.folderNamePlaceholder, text: $viewModel.newFolderName)
                            .textInputAutocapitalization(.words)
                    }
                    .navigationTitle(L10n.FolderPicker.createNewFolder)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(L10n.Common.cancel) {
                                viewModel.newFolderName = ""
                                viewModel.showCreateFolder = false
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.Common.create) {
                                Task { await viewModel.createNewFolder() }
                            }
                            .disabled(viewModel.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let error = viewModel.errorMessage {
                    VStack {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(8)
                            .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                            .padding()
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}
