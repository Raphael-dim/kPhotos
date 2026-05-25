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

import kPhotosCore
import kPhotosCoreUI
import kPhotosResources
import SwiftUI

public struct AlbumDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AlbumDetailViewModel
    @State private var photoToRemove: PhotoSnapshot?
    @State private var isRenamePresented = false
    @State private var renameText = ""
    @State private var isDeleteConfirmPresented = false
    @Namespace private var tileNamespace

    /// Même paramètres que la grille principale (cf. `TimelineView`) pour avoir
    /// un rendu identique.
    private let columnCount = 3
    private let gridSpacing: CGFloat = 3

    public init(album: AlbumSnapshot) {
        _viewModel = StateObject(wrappedValue: AlbumDetailViewModel(album: album))
    }

    public var body: some View {
        content
            .navigationTitle(viewModel.album.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .toolbar { albumMenu }
            .sheet(isPresented: $isRenamePresented) {
                renameSheet
            }
            .confirmationDialog(
                L10n.Albums.deleteConfirmTitle,
                isPresented: $isDeleteConfirmPresented,
                titleVisibility: .visible
            ) {
                Button(L10n.Albums.delete, role: .destructive) {
                    Task {
                        if await viewModel.deleteAlbum() { dismiss() }
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Albums.deleteConfirmMessage)
            }
            .confirmationDialog(
                photoToRemove?.name ?? "",
                isPresented: Binding(
                    get: { photoToRemove != nil },
                    set: { if !$0 { photoToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let photo = photoToRemove {
                    Button(L10n.Common.delete, role: .destructive) {
                        Task {
                            await viewModel.removePhoto(fileId: photo.fileId)
                            photoToRemove = nil
                        }
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) { photoToRemove = nil }
            }
    }

    @ToolbarContentBuilder
    private var albumMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    renameText = viewModel.album.name
                    isRenamePresented = true
                } label: {
                    Label(L10n.Albums.rename, systemImage: "pencil")
                }
                Button(role: .destructive) {
                    isDeleteConfirmPresented = true
                } label: {
                    Label(L10n.Albums.delete, systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.Albums.createPlaceholder, text: $renameText)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle(L10n.Albums.renameTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Common.cancel) { isRenamePresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.confirm) {
                        Task {
                            await viewModel.rename(to: renameText)
                            isRenamePresented = false
                        }
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.photos.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            ErrorStateView(
                title: L10n.Common.errorGeneric,
                message: error,
                retryTitle: L10n.Common.retry,
                onRetry: { Task { await viewModel.load() } }
            )
        } else if viewModel.photos.isEmpty {
            EmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: L10n.Albums.emptyAlbumTitle,
                subtitle: L10n.Albums.emptyAlbumSubtitle
            )
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - (gridSpacing * CGFloat(columnCount - 1))
            let tileSize = max(72, available / CGFloat(columnCount))

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount),
                    spacing: gridSpacing
                ) {
                    ForEach(viewModel.photos) { photo in
                        GalleryTile(
                            item: GalleryItem.fromCloud(photo),
                            size: tileSize,
                            namespace: tileNamespace,
                            isSelected: false,
                            onTap: { /* viewer plein écran : phase suivante */ },
                            onShowFailureReason: { _, _ in },
                            onShowDeletionFailure: { _, _ in }
                        )
                        .contextMenu {
                            Button(role: .destructive) {
                                photoToRemove = photo
                            } label: {
                                Label(L10n.Common.delete, systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }
}
