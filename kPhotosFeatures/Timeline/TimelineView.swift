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
import UIKit

public struct TimelineView: View {
    @StateObject private var viewModel: TimelineViewModel
    @StateObject private var gridInteraction: TimelineGridInteraction
    @State private var detailedError: String?
    @State private var itemFailureSheet: ItemFailureSheet?
    @State private var deletionFailureSheet: DeletionFailureSheet?
    @State private var isShowingBackupDetails = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewerPresentation: TimelineViewerPresentation?
    @State private var viewerGalleryItemID: String?
    @Namespace private var viewerNamespace
    @State private var navigationTitle = L10n.Timeline.title
    @State private var toast: SyncToast?
    /// Identifiant du toast en cours d'auto-dismiss. Sert à ignorer un dismiss
    /// programmé si un nouveau toast est apparu entre-temps.
    @State private var toastDismissID: UUID?
    @State private var showDeleteConfirm = false
    @State private var showAlbumPicker = false
    @State private var selectedAlbums: [AlbumSnapshot] = []
    public init() {
        let model = TimelineViewModel()
        _viewModel = StateObject(wrappedValue: model)
        _gridInteraction = StateObject(wrappedValue: TimelineGridInteraction(viewModel: model))
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.large)
                .task { await viewModel.load() }
                .toolbar { toolbarContent }
                .sheet(isPresented: $isShowingBackupDetails) {
                    BackupDetailsSheet(viewModel: viewModel)
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { viewModel.refreshLocalBackupInventory() }
                }
                .sheet(isPresented: Binding(
                    get: { detailedError != nil },
                    set: { if !$0 { detailedError = nil } }
                )) {
                    errorDetailSheet
                }
                .sheet(item: $itemFailureSheet) { failure in
                    TimelineBackupFailureSheet(failure: failure, viewModel: viewModel, onClose: { itemFailureSheet = nil })
                }
                // Plein écran modal — couvre la TabBar et la toolbar de navigation.
                // Le viewer remplit ainsi tout l'écran comme dans l'app Photos d'iOS.
                .fullScreenCover(item: $viewerPresentation) { presentation in
                    FullscreenMediaView(
                        media: presentation.media,
                        initialIndex: presentation.index,
                        namespace: viewerNamespace,
                        onCurrentMediaChange: { mediaID in
                            viewerGalleryItemID = presentation.galleryItemIDs[mediaID]
                        },
                        onClose: { viewerPresentation = nil }
                    )
                }
                // Reserve room for selection actions instead of covering the last row.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if viewModel.isSelectionModeActive {
                        SelectionToolbar(
                            selectedCount: viewModel.selectionManager.count,
                            onCancel: { viewModel.clearSelection() },
                            onDelete: { showDeleteConfirm = true },
                            onDownload: {
                                Task {
                                    do {
                                        let count = try await viewModel.downloadSelected()
                                        hapticSuccess()
                                        presentToast(.init(
                                            kind: .success,
                                            message: L10n.Timeline.Selection.downloadedToLibrary(count: count),
                                            errorDetail: nil
                                        ))
                                    } catch {
                                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                                        presentToast(.init(
                                            kind: .error,
                                            message: error.localizedDescription,
                                            errorDetail: nil
                                        ))
                                    }
                                }
                            },
                            onAddToAlbum: { showAlbumPicker = true }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // Toast en bas (au-dessus de la TabBar) — `.bottom` respecte le
                // safeArea du tabbar donc on est jamais caché par la nav système.
                .overlay(alignment: .bottom) {
                    if let toast, !viewModel.isSelectionModeActive {
                        SyncToastView(toast: toast) {
                            if let detail = toast.errorDetail {
                                detailedError = detail
                            }
                            dismissToast(id: toast.id)
                        }
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .confirmationDialog(
                    L10n.Timeline.Selection.deleteTitle,
                    isPresented: $showDeleteConfirm,
                    actions: {
                        Button(L10n.Common.delete, role: .destructive) {
                            Task {
                                hapticFeedback(.heavy)
                                // Pas de toast "Suppression de N…" : les badges
                                // animés (spinner rouge) sur les tiles signalent
                                // déjà l'opération en cours. Le toast récapitulatif
                                // de fin de drain (`lastDeletionSummary`) confirme
                                // le succès final ; les échecs ont leur propre toast.
                                await viewModel.deleteSelected()
                            }
                        }
                        Button(L10n.Common.cancel, role: .cancel) {}
                    },
                    message: {
                        let count = viewModel.selectionManager.count
                        Text(L10n.Timeline.Selection.deleteMessage(count: count))
                    }
                )
                .sheet(isPresented: $showAlbumPicker) {
                    albumPickerContent
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toast)
                // Réagit aux transitions terminale (succès / erreur) pour notifier
                // discrètement l'utilisateur. La phase `.running` est représentée
                // uniquement par l'indicateur dans le toolbar.
                .onChange(of: viewModel.syncState) { newState in
                    if let notice = SyncToast.forSyncState(newState) { presentToast(notice) }
                }
                // Récap en fin de drain — un toast unique qui résume "N supprimées"
                // (ou "N supprimées, M échouées" si mixte). Remplace le toast
                // "Suppression de N…" affiché à l'enqueue, pour donner une
                // confirmation visuelle franche que l'opération est terminée.
                .onChange(of: viewModel.lastDeletionSummary) { summary in
                    guard let summary, summary.completed > 0 else { return }
                    presentToast(
                        .init(
                            kind: .success,
                            message: L10n.Timeline.Selection.deletedCount(count: summary.completed),
                            errorDetail: nil
                        )
                    )
                    viewModel.clearDeletionSummary()
                }
                // Échecs de suppression remontés en fin de drain — toast tappable
                // qui ouvre le détail du premier item en échec. Si plusieurs photos
                // ont échoué, l'utilisateur peut ouvrir le badge rouge des autres
                // tiles pour les traiter individuellement.
                .onChange(of: viewModel.lastDeletionFailures) { failures in
                    guard !failures.isEmpty else { return }
                    let firstReason = failures.first?.reason ?? ""
                    presentToast(
                        .init(
                            kind: .error,
                            message: L10n.Timeline.Deletion.failedToast(failures.count),
                            errorDetail: firstReason.isEmpty ? nil : firstReason
                        )
                    )
                    viewModel.clearDeletionFailures()
                }
                .sheet(item: $deletionFailureSheet) { failure in
                    TimelineDeletionFailureSheet(failure: failure, viewModel: viewModel, onClose: { deletionFailureSheet = nil })
                }
                .task {
                    selectedAlbums = await viewModel.loadAlbums()
                }
        }
    }

    private func presentToast(_ newToast: SyncToast) {
        toast = newToast
        toastDismissID = newToast.id
        let lifetime: TimeInterval = newToast.kind == .error ? 5 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            // Ne dismiss que si aucun nouveau toast n'a remplacé celui-ci.
            if toastDismissID == newToast.id {
                toast = nil
            }
        }
    }

    private func dismissToast(id: UUID) {
        if toast?.id == id { toast = nil }
    }

    private var errorDetailSheet: some View {
        TimelineErrorDetailSheet(message: detailedError ?? "", onClose: { detailedError = nil })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .appPrimaryAction) {
            if case .ready = viewModel.state {
                Button { isShowingBackupDetails = true } label: {
                    LibraryStatusGlyph(
                        symbol: viewModel.backupOverview.symbol,
                        tone: viewModel.backupOverview.tone,
                        progress: viewModel.backupOverview.phase == .saving ? viewModel.backupOverview.fraction : nil,
                        size: 28
                    )
                }
                .accessibilityLabel(L10n.Backup.title)
                .accessibilityValue(viewModel.backupOverview.title)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .permissionNeeded:
            EmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: L10n.Timeline.permissionTitle,
                subtitle: L10n.Timeline.permissionSubtitle,
                actionTitle: L10n.Timeline.permissionAction,
                action: { Task { await viewModel.requestPhotoLibraryAccess() } }
            )
        case .permissionDenied:
            EmptyStateView(
                systemImage: "lock.shield",
                title: L10n.Timeline.permissionDeniedTitle,
                subtitle: L10n.Timeline.permissionDeniedSubtitle
            )
        case .noDriveSelected:
            EmptyStateView(
                systemImage: "externaldrive.badge.questionmark",
                title: L10n.Timeline.noDriveTitle,
                subtitle: L10n.Timeline.noDriveSubtitle
            )
        case .ready(let summary, let sections):
            readyView(summary: summary, sections: sections)
        case .error(let message):
            ErrorStateView(
                title: L10n.Common.errorGeneric,
                message: message,
                retryTitle: L10n.Common.retry,
                onRetry: { Task { await viewModel.load() } }
            )
        }
    }

    @ViewBuilder
    private func readyView(summary: PhotoLibrarySummary, sections: [GallerySection]) -> some View {
        if sections.isEmpty {
            VStack {
                libraryActivity.padding(.horizontal, 20)
                EmptyStateView(
                    systemImage: "checkmark.icloud",
                    title: L10n.Timeline.libraryTitle,
                    subtitle: L10n.Timeline.librarySubtitle(
                        photos: summary.photosCount,
                        videos: summary.videosCount
                    )
                )
            }
        } else {
            TimelineGridView(
                viewModel: viewModel,
                interaction: gridInteraction,
                sections: sections,
                namespace: viewerNamespace,
                viewerGalleryItemID: viewerGalleryItemID,
                isViewerPresented: viewerPresentation != nil,
                actions: .init(
                    onOpen: { handleTap(on: $0) },
                    onBackupFailure: { itemFailureSheet = ItemFailureSheet(localIdentifier: $0, reason: $1) },
                    onDeletionFailure: { deletionFailureSheet = DeletionFailureSheet(fileId: $0, reason: $1) },
                    onShowBackup: { isShowingBackupDetails = true },
                    onTitleChange: { navigationTitle = $0 }
                )
            )
        }
    }

    private var libraryActivity: some View {
        TimelineLibraryStatus(viewModel: viewModel, onOpen: { isShowingBackupDetails = true })
    }

    private func handleTap(on item: GalleryItem) {
        // Protection multi-touch : un tap "accidentel" déclenché par un second doigt
        // pendant qu'un drag-select est en cours ne doit pas perturber la sélection.
        // On ignore activement le tap tant que l'anchor est posé.
        if viewModel.isSelectionModeActive {
            viewModel.toggleSelection(itemId: item.id)
            hapticFeedback(.light)
        } else {
            guard let media = viewModel.viewerMedia(for: item) else { return }
            let allMedia = viewModel.orderedViewerMedia
            let index = allMedia.firstIndex(where: { $0.id == media.id }) ?? 0
            guard case .ready(_, let sections) = viewModel.state else { return }
            let galleryItemIDs = Dictionary(
                sections.flatMap(\.items).map { ($0.viewerTransitionID, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            viewerGalleryItemID = nil
            viewerPresentation = TimelineViewerPresentation(media: allMedia, index: index, galleryItemIDs: galleryItemIDs)
        }
    }

    private func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func hapticSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @ViewBuilder private var albumPickerContent: some View {
        AlbumPickerSheet(
            albums: selectedAlbums,
            onSelect: { album in
                Task {
                    await viewModel.addSelectedToAlbum(albumId: album.id)
                    hapticSuccess()
                    presentToast(
                        .init(
                            kind: .success,
                            message: L10n.Timeline.Selection.addedToAlbum(album: album.name),
                            errorDetail: nil
                        )
                    )
                    showAlbumPicker = false
                }
            }
        )
    }
}
