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
import kPhotosResources
import SwiftUI

public struct AlbumsView: View {
    @StateObject private var viewModel = AlbumsViewModel()
    @State private var isCreatePresented = false
    @State private var newAlbumName = ""
    @State private var albumToRename: AlbumSnapshot?
    @State private var renameText = ""
    @State private var albumToDelete: AlbumSnapshot?

    /// 2 colonnes, style Google/Apple Photos.
    private let columnCount = 2
    private let outerPadding: CGFloat = 12
    private let gridSpacing: CGFloat = 12

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.Albums.title)
                .task { await viewModel.load() }
                .refreshable { await viewModel.load() }
                .toolbar { toolbarContent }
                .sheet(isPresented: $isCreatePresented) {
                    createAlbumSheet
                }
                .sheet(item: $albumToRename) { album in
                    renameAlbumSheet(album)
                }
                .confirmationDialog(
                    L10n.Albums.deleteConfirmTitle,
                    isPresented: Binding(
                        get: { albumToDelete != nil },
                        set: { if !$0 { albumToDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: albumToDelete
                ) { album in
                    Button(L10n.Albums.delete, role: .destructive) {
                        Task {
                            await viewModel.deleteAlbum(albumId: album.id)
                            albumToDelete = nil
                        }
                    }
                    Button(L10n.Common.cancel, role: .cancel) { albumToDelete = nil }
                } message: { _ in
                    Text(L10n.Albums.deleteConfirmMessage)
                }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .appPrimaryAction) {
            Button {
                newAlbumName = ""
                isCreatePresented = true
            } label: {
                Label(L10n.Albums.create, systemImage: "plus")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noDriveSelected:
            EmptyStateView(
                systemImage: "externaldrive.badge.questionmark",
                title: L10n.Albums.noDriveTitle,
                subtitle: L10n.Albums.noDriveSubtitle
            )
        case .empty:
            EmptyStateView(
                systemImage: "rectangle.stack.badge.plus",
                title: L10n.Albums.emptyTitle,
                subtitle: L10n.Albums.emptySubtitle,
                actionTitle: L10n.Albums.create,
                action: {
                    newAlbumName = ""
                    isCreatePresented = true
                }
            )
        case .ready(let albums):
            albumsGrid(albums)
        case .error(let message):
            ErrorStateView(
                title: L10n.Common.errorGeneric,
                message: message,
                retryTitle: L10n.Common.retry,
                onRetry: { Task { await viewModel.load() } }
            )
        }
    }

    private func albumsGrid(_ albums: [AlbumSnapshot]) -> some View {
        GeometryReader { proxy in
            let usable = proxy.size.width - (outerPadding * 2) - (gridSpacing * CGFloat(columnCount - 1))
            let tileSize = max(120, usable / CGFloat(columnCount))

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount),
                    spacing: gridSpacing + 4
                ) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            AlbumCard(album: album, coverSize: tileSize)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renameText = album.name
                                albumToRename = album
                            } label: {
                                Label(L10n.Albums.rename, systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                albumToDelete = album
                            } label: {
                                Label(L10n.Albums.delete, systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, outerPadding)
                .padding(.vertical, outerPadding)
            }
        }
    }

    private var createAlbumSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.Albums.createPlaceholder, text: $newAlbumName)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle(L10n.Albums.create)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel, role: .cancel) { isCreatePresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.confirm, role: .appConfirmation) {
                        Task {
                            await viewModel.createAlbum(name: newAlbumName)
                            isCreatePresented = false
                        }
                    }
                    .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func renameAlbumSheet(_ album: AlbumSnapshot) -> some View {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel, role: .cancel) { albumToRename = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.confirm, role: .appConfirmation) {
                        Task {
                            await viewModel.renameAlbum(albumId: album.id, name: renameText)
                            albumToRename = nil
                        }
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - AlbumCard

private struct AlbumCard: View {
    let album: AlbumSnapshot
    let coverSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumCoverThumbnail(album: album, size: coverSize)
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(album.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(L10n.Albums.photoCount(count: album.photoCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AlbumCoverThumbnail

/// Cover carrée d'un album.
/// - Si `album.coverPhotoId` est connue : `CloudThumbnail` (même cache que la
///   timeline, RAM → disque → API).
/// - Sinon : placeholder + résolution best-effort via `AlbumManaging.resolveCover`
///   au `task` initial (1 appel `listCategoryFiles(limit:1)` qui persiste l'id
///   en Realm pour les prochains affichages).
private struct AlbumCoverThumbnail: View {
    let album: AlbumSnapshot
    let size: CGFloat
    @State private var coverFileId: String
    @InjectService private var albumManager: AlbumManaging

    init(album: AlbumSnapshot, size: CGFloat) {
        self.album = album
        self.size = size
        _coverFileId = State(initialValue: album.coverPhotoId)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if !coverFileId.isEmpty {
                CloudThumbnail(driveId: album.driveId, fileId: coverFileId, size: size)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .task {
            guard coverFileId.isEmpty else { return }
            if let resolved = try? await albumManager.resolveCover(albumId: album.id, driveId: album.driveId),
               !resolved.isEmpty {
                coverFileId = resolved
            }
        }
    }
}
