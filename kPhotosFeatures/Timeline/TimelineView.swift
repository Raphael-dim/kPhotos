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

// Preference key pour remonter la position verticale des en-têtes de section
// afin de mettre à jour le titre de navigation dynamiquement.
private struct SectionAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

// Frames absolus des tiles dans l'espace global. Sert au drag-to-select pour
// hit-tester l'item sous le doigt sans avoir à descendre dans la hiérarchie.
private struct TileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// Frame global du ScrollView — utilisé pour déterminer les zones d'auto-scroll
// (haut/bas) pendant le drag-select.
private struct ScrollFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private enum AutoScrollDirection { case up, down }

/// Wrapper Identifiable pour pouvoir passer l'état du viewer à `.fullScreenCover(item:)`.
private struct ViewerPresentation: Identifiable {
    let id = UUID()
    let media: [ViewerMedia]
    let index: Int
}

/// Notification in-app affichée brièvement (toast) à la fin d'une synchronisation.
private struct SyncToast: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let message: String
    /// Détail d'erreur — non nil quand `kind == .error`, ouvert au tap du toast.
    let errorDetail: String?

    enum Kind { case success, error }
}

/// Données affichées par la sheet de détail d'échec **par photo**. Distincte de
/// `detailedError: String?` (sheet d'erreur globale de session sync) — celle-ci
/// porte le `localIdentifier` pour permettre les actions "Réessayer" / "Ignorer".
private struct ItemFailureSheet: Identifiable {
    let id = UUID()
    let localIdentifier: String
    let reason: String
}

/// Sheet d'échec de suppression par photo — distinct de l'upload car les
/// actions diffèrent (retry suppression vs annuler suppression, pas de skip).
private struct DeletionFailureSheet: Identifiable {
    let id = UUID()
    let fileId: String
    let reason: String
}

public struct TimelineView: View {
    @StateObject private var viewModel = TimelineViewModel()
    @State private var isShowingBackupDetails = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var detailedError: String?
    @State private var itemFailureSheet: ItemFailureSheet?
    @State private var deletionFailureSheet: DeletionFailureSheet?
    @State private var isShowingSyncOptions = false
    @State private var viewerPresentation: ViewerPresentation?
    @Namespace private var viewerNamespace
    @State private var navigationTitle = L10n.Timeline.title
    /// Index du niveau de densité courant dans `Self.zoomLevels`. La grille a un
    /// nombre de colonnes discret ; le pinch fait basculer d'un cran à l'autre.
    @State private var zoomLevelIndex = Self.defaultZoomLevelIndex
    /// Échelle homothétique appliquée en direct à la grille pendant le pinch
    /// (`.scaleEffect`). 1.0 = état stable. Animée vers 1.0 à la fin du geste —
    /// soit en se figeant sur le nouveau niveau, soit en ressort inverse.
    @State private var gestureScale: CGFloat = 1.0
    /// Épicentre du pinch — point médian des deux doigts, exprimé en `UnitPoint`
    /// du conteneur. Sert d'ancrage au `.scaleEffect` : le contenu sous ce point
    /// reste rigoureusement fixe pendant tout le geste.
    @State private var gestureAnchor: UnitPoint = .center
    /// `true` entre le début et la fin d'un pinch valide. Garde anti-rebond pour
    /// `onChanged`/`onEnded` quand le geste a été ignoré au départ (drag-select actif).
    @State private var isPinching = false
    /// Tile sous l'épicentre au début du pinch — cible du recentrage du scroll
    /// après un changement de niveau, pour que la zone visée reste à l'écran.
    @State private var pinchAnchorTileId: String?
    /// Position verticale de l'épicentre dans le viewport au début du pinch
    /// (0 = haut, 1 = bas). Réutilisée comme ancre du `scrollTo` post-snap.
    @State private var pinchAnchorViewportFraction: CGFloat = 0.5
    /// `true` quand l'échelle courante a franchi le seuil de bascule — pilote le
    /// petit retour haptique « cran prêt » et évite de le rejouer en continu.
    @State private var pinchArmedForCommit = false
    /// Frames absolus de toutes les tiles visibles, capturées via PreferenceKey.
    /// Sert au hit-testing du drag-to-select sans descendre dans la hiérarchie.
    @State private var tileFrames: [String: CGRect] = [:]
    /// Frame absolu du ScrollView, utilisé pour décider quand auto-scroller
    /// (zone tampon = 10% des bords haut/bas) et pour la vitesse proportionnelle.
    @State private var scrollViewGlobalFrame: CGRect = .zero
    /// Item d'ancrage du drag-to-select — set quand le long-press confirme,
    /// nil quand le geste se termine. Sert aussi de garde multi-touch : tout
    /// long-press secondaire pendant qu'un anchor est déjà actif est ignoré.
    @State private var dragSelectAnchorId: String?
    /// Snapshot de la sélection au moment où le long-press fire. La règle de
    /// composition pendant le drag est `selection = snapshot ∪ range_courante`,
    /// ce qui donne automatiquement la désélection en marche arrière (les items
    /// quittant la range disparaissent de la sélection s'ils n'étaient pas
    /// initialement sélectionnés).
    @State private var dragSelectInitialSelection: Set<String> = []
    /// Dernière position globale du doigt — réutilisée par l'auto-scroll quand
    /// la grille défile sans que le doigt bouge (le hit-test doit alors être
    /// recalculé avec les nouvelles positions des tiles).
    @State private var lastDragLocation: CGPoint?
    /// Timer d'auto-scroll pendant le drag-select (zone tampon haut/bas).
    @State private var autoScrollTimer: Timer?
    /// Intensité de l'auto-scroll en [0, 1] — 0 = entrée dans la zone, 1 = bord
    /// absolu. Recalculée à chaque mouvement du doigt.
    @State private var autoScrollIntensity: CGFloat = 0
    @State private var autoScrollDirection: AutoScrollDirection = .down
    /// Accumulateur de rows fractionnaires — permet d'avancer de "0.3 row" par
    /// tick à faible intensité sans perdre la fraction d'un tick à l'autre.
    @State private var autoScrollRowAccumulator: CGFloat = 0
    /// Référence au `UIScrollView` sous-jacent à la SwiftUI `ScrollView`, captée
    /// par introspection (`ScrollViewIntrospector` placé dans le contenu). On
    /// l'utilise pour piloter l'auto-scroll en `setContentOffset(_:animated:)`
    /// — qui fonctionne même quand `isScrollEnabled = false`, contrairement au
    /// `ScrollViewProxy.scrollTo` qui peut être bloqué par `.scrollDisabled(...)`.
    @State private var underlyingScrollView: UIScrollView?
    @State private var toast: SyncToast?
    /// Identifiant du toast en cours d'auto-dismiss. Sert à ignorer un dismiss
    /// programmé si un nouveau toast est apparu entre-temps.
    @State private var toastDismissID: UUID?
    @State private var showDeleteConfirm = false
    @State private var showAlbumPicker = false
    @State private var selectedAlbums: [AlbumSnapshot] = []
    /// Niveaux de densité discrets, du plus grand format (1 colonne) à la vue
    /// ultra-dense. Le pinch fait passer d'un cran au cran adjacent.
    private static let zoomLevels = [1, 3, 5, 7]
    /// Niveau affiché à l'ouverture (3 colonnes).
    private static let defaultZoomLevelIndex = 1
    /// Seuil d'échelle au-delà duquel écarter les doigts fige la grille sur un
    /// niveau plus grand (moins de colonnes).
    private let zoomInCommitThreshold: CGFloat = 1.35
    /// Seuil d'échelle en deçà duquel pincer fige la grille sur un niveau plus
    /// dense (plus de colonnes).
    private let zoomOutCommitThreshold: CGFloat = 0.78

    /// Nombre de colonnes du niveau de densité courant.
    private var columnCount: Int { Self.zoomLevels[zoomLevelIndex] }

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.automatic)
                .task { await viewModel.load() }
                .toolbar { toolbarContent }
                .sheet(isPresented: $isShowingBackupDetails) {
                    BackupDetailsSheet(viewModel: viewModel)
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { viewModel.refreshLocalBackupInventory() }
                }
                .sheet(isPresented: $isShowingSyncOptions) {
                    SyncOptionsView()
                }
                .sheet(isPresented: Binding(
                    get: { detailedError != nil },
                    set: { if !$0 { detailedError = nil } }
                )) {
                    errorDetailSheet
                }
                .sheet(item: $itemFailureSheet) { failure in
                    itemFailureSheetView(failure)
                }
                // Plein écran modal — couvre la TabBar et la toolbar de navigation.
                // Le viewer remplit ainsi tout l'écran comme dans l'app Photos d'iOS.
                .fullScreenCover(item: $viewerPresentation) { presentation in
                    FullscreenMediaView(
                        media: presentation.media,
                        initialIndex: presentation.index,
                        namespace: viewerNamespace,
                        onClose: { viewerPresentation = nil }
                    )
                }
                // Selection toolbar
                .overlay(alignment: .bottom) {
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
                    handleSyncStateChange(newState)
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
                    deletionFailureSheetView(failure)
                }
                .task {
                    selectedAlbums = await viewModel.loadAlbums()
                }
        }
    }

    private func handleSyncStateChange(_ state: TimelineViewModel.SyncState) {
        switch state {
        case .finished(let progress):
            presentToast(
                .init(
                    kind: .success,
                    message: L10n.Timeline.syncDone(uploaded: progress.completed),
                    errorDetail: nil
                )
            )
        case .failed(let message):
            presentToast(
                .init(
                    kind: .error,
                    message: L10n.Common.errorGeneric,
                    errorDetail: message
                )
            )
        case .idle, .running:
            break
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

    @ViewBuilder
    private var errorDetailSheet: some View {
        NavigationStack {
            ScrollView {
                Text(detailedError ?? "")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(L10n.Timeline.errorDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close) { detailedError = nil }
                }
            }
        }
    }

    /// Sheet par-item : titre "Sauvegarde impossible", message lisible, deux
    /// actions explicites. La fermeture est aussi possible via le drag standard
    /// d'une sheet — pas de bouton "Annuler" en plus pour rester épuré.
    @ViewBuilder
    private func itemFailureSheetView(_ failure: ItemFailureSheet) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 20)

                Text(failure.reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Button {
                        let localId = failure.localIdentifier
                        itemFailureSheet = nil
                        Task { await viewModel.retryItem(localIdentifier: localId) }
                    } label: {
                        Label(L10n.Timeline.Backup.retryItem, systemImage: "arrow.clockwise.icloud")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        let localId = failure.localIdentifier
                        itemFailureSheet = nil
                        Task { await viewModel.skipItem(localIdentifier: localId) }
                    } label: {
                        Label(L10n.Timeline.Backup.skipItem, systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle(L10n.Timeline.Backup.failureTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close) { itemFailureSheet = nil }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Sheet par-item pour les échecs de suppression. Actions : réessayer le
    /// DELETE (re-queue + drain) ou annuler la suppression (purge le DeletionItem,
    /// la photo redevient normale dans la galerie).
    @ViewBuilder
    private func deletionFailureSheetView(_ failure: DeletionFailureSheet) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.top, 20)

                Text(failure.reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Button {
                        let id = failure.fileId
                        deletionFailureSheet = nil
                        Task { await viewModel.retryDeletion(fileId: id) }
                    } label: {
                        Label(L10n.Timeline.Deletion.retryItem, systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .cancel) {
                        let id = failure.fileId
                        deletionFailureSheet = nil
                        Task { await viewModel.cancelDeletion(fileId: id) }
                    } label: {
                        Label(L10n.Timeline.Deletion.cancelItem, systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle(L10n.Timeline.Deletion.failureTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close) { deletionFailureSheet = nil }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    /// Pendant la synchronisation, on affiche une fine progression circulaire
    /// autour d'un icône cloud minuscule. Subtile et informative — le pourcentage
    /// est lisible au coin d'œil sans saturer la toolbar.
    @ViewBuilder
    private var syncMenuLabel: some View {
        switch viewModel.syncState {
        case .running(let progress) where progress.total > 0:
            CircularSyncIndicator(progress: progress.fraction)
        case .running:
            // Total inconnu au tout début : on a juste un spinner indéterminé.
            ProgressView().controlSize(.small)
        case .idle, .finished, .failed:
            Image(systemName: "icloud.and.arrow.up")
        }
    }

    private var isSyncing: Bool {
        if case .running = viewModel.syncState { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
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
            sectionsList(sections)
        }
    }

    private var libraryActivity: some View {
        LibraryStatusButton(
            title: viewModel.backupOverview.title,
            subtitle: viewModel.backupOverview.subtitle,
            symbol: viewModel.backupOverview.symbol,
            tone: viewModel.backupOverview.tone,
            progress: viewModel.backupOverview.phase == .saving ? viewModel.backupOverview.fraction : nil,
            action: { isShowingBackupDetails = true }
        )
    }

    private func sectionsList(_ sections: [GallerySection]) -> some View {
        GeometryReader { proxy in
            let gridSpacing: CGFloat = 3
            let available = proxy.size.width - (gridSpacing * CGFloat(columnCount - 1))
            // Plancher purement défensif — jamais atteint pour `zoomLevels` (max
            // 7 colonnes), il évite seulement une taille dégénérée si la largeur
            // disponible devenait nulle pendant une transition de layout.
            let tileSize = max(36, available / CGFloat(columnCount))

            // ScrollViewReader = pré-requis pour l'auto-scroll programmatique
            // pendant le drag-select aux bords (scrollTo(id, anchor:)).
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                        libraryActivity.padding(.horizontal, 16)
                        // Sonde invisible placée À L'INTÉRIEUR du content de la
                        // ScrollView : on remonte la chaîne de superviews pour
                        // capter le `UIScrollView` UIKit sous-jacent à la SwiftUI
                        // ScrollView. Permet ensuite de piloter le scroll en
                        // `setContentOffset(_:animated:)` (qui marche même avec
                        // `isScrollEnabled = false`) au lieu de passer par
                        // `ScrollViewProxy.scrollTo` qui peut être bloqué par
                        // `.scrollDisabled(...)`.
                        ScrollViewIntrospector { sv in
                            if underlyingScrollView !== sv {
                                underlyingScrollView = sv
                            }
                        }
                        .frame(width: 0, height: 0)

                        // Sonde de pinch — branche un `UIPinchGestureRecognizer`
                        // sur l'`UIScrollView` sous-jacent pour piloter le zoom
                        // de densité avec l'épicentre exact du geste.
                        pinchDetector(scrollProxy: scrollProxy)
                            .frame(width: 0, height: 0)

                        ForEach(sections, id: \.id) { section in
                            sectionRow(section, tileSize: tileSize, gridSpacing: gridSpacing)
                        }
                    }
                    .padding(.vertical, 16)
                    // Transformation homothétique du pinch, ancrée sur l'épicentre
                    // du geste : le contenu sous le point médian des doigts reste
                    // strictement fixe pendant tout le zoom (cf. PinchZoomDetector).
                    .scaleEffect(gestureScale, anchor: gestureAnchor)
                }
                .coordinateSpace(name: "timelineScroll")
                // Scrubber natif iOS : indicateur de scroll visible sur la droite.
                .scrollIndicators(.visible)
                // Pendant le drag-select on bloque le pan utilisateur — sinon
                // tirer le doigt vers le bas ferait remonter la grille (sens
                // naturel du pan), l'inverse de ce qu'on veut. L'auto-scroll
                // utilise `setContentOffset` via l'introspecteur, qui n'est
                // PAS affecté par `scrollDisabled`.
                .scrollDisabled(dragSelectAnchorId != nil)
                // Le geste long-press + drag-to-select est posé UNE SEULE FOIS sur la
                // ScrollView (pas par tile). C'est crucial pour le scroll : attacher un
                // geste à chaque tile bloque les touches au niveau de la tile et
                // empêche la ScrollView de voir le pan. Ici, en simultaneousGesture sur
                // la ScrollView elle-même, on coexiste avec le pan natif d'UIScrollView.
                // Pendant les 500ms d'attente, si le doigt glisse, le long-press
                // se cancel et le scroll prend naturellement. La tile sous le doigt
                // est résolue via hit-test sur `tileFrames` (publiés par chaque tile
                // via PreferenceKey).
                .simultaneousGesture(dragSelectMasterGesture(scrollProxy: scrollProxy))
                .refreshable {
                    await viewModel.refreshCloud()
                }
                .background(
                    GeometryReader { scrollGeo in
                        Color.clear.preference(
                            key: ScrollFramePreferenceKey.self,
                            value: scrollGeo.frame(in: .global)
                        )
                    }
                )
                .onPreferenceChange(SectionAnchorPreferenceKey.self) { positions in
                    let threshold: CGFloat = -90
                    if let current = positions
                        .filter({ $0.value < threshold })
                        .max(by: { $0.value < $1.value }) {
                        navigationTitle = current.key
                    } else {
                        navigationTitle = L10n.Timeline.title
                    }
                }
                .onPreferenceChange(TileFramePreferenceKey.self) { frames in
                    tileFrames = frames
                }
                .onPreferenceChange(ScrollFramePreferenceKey.self) { frame in
                    scrollViewGlobalFrame = frame
                }
                .onDisappear { stopAutoScroll() }
            }
        }
    }

    private func sectionRow(_ section: GallerySection, tileSize: CGFloat, gridSpacing: CGFloat) -> some View {
        let title = Self.sectionTitle(for: section)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(sectionTitleFont)
                if showsSectionCount {
                    Text(L10n.Timeline.sectionCount(count: section.items.count))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SectionAnchorPreferenceKey.self,
                        value: [title: geo.frame(in: .named("timelineScroll")).minY]
                    )
                }
            )

            LazyVGrid(
                columns: gridColumns(count: columnCount, spacing: gridSpacing),
                spacing: gridSpacing
            ) {
                ForEach(section.items) { item in
                    GalleryTile(
                        item: item,
                        size: tileSize,
                        namespace: viewerNamespace,
                        isSelected: viewModel.selectionManager.isSelected(item.id),
                        onTap: { handleTap(on: item) },
                        onShowFailureReason: { localId, reason in
                            itemFailureSheet = ItemFailureSheet(
                                localIdentifier: localId,
                                reason: reason
                            )
                        },
                        onShowDeletionFailure: { fileId, reason in
                            deletionFailureSheet = DeletionFailureSheet(
                                fileId: fileId,
                                reason: reason
                            )
                        }
                    )
                }
            }
        }
    }

    private func handleTap(on item: GalleryItem) {
        // Protection multi-touch : un tap "accidentel" déclenché par un second doigt
        // pendant qu'un drag-select est en cours ne doit pas perturber la sélection.
        // On ignore activement le tap tant que l'anchor est posé.
        guard dragSelectAnchorId == nil else { return }
        if viewModel.isSelectionModeActive {
            viewModel.toggleSelection(itemId: item.id)
            hapticFeedback(.light)
        } else {
            guard let media = viewModel.viewerMedia(for: item) else { return }
            let allMedia = viewModel.orderedViewerMedia
            let index = allMedia.firstIndex(where: { $0.id == media.id }) ?? 0
            viewerPresentation = ViewerPresentation(media: allMedia, index: index)
        }
    }

    private static func sectionTitle(for section: GallerySection) -> String {
        var components = DateComponents()
        components.year = section.year
        components.month = section.month
        let date = Calendar.iso8601.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date).capitalized
    }

    private func gridColumns(count: Int, spacing: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    /// Police du titre de section — imposante en grand format, compacte en vue
    /// dense : l'en-tête de date « se range » à mesure que la grille se densifie.
    private var sectionTitleFont: Font {
        switch columnCount {
        case ...1: return .title.weight(.bold)
        case 2 ... 3: return .title3.weight(.semibold)
        case 4 ... 5: return .subheadline.weight(.semibold)
        default: return .caption.weight(.bold)
        }
    }

    /// Espacement vertical entre sections — se resserre quand la grille se densifie.
    private var sectionSpacing: CGFloat {
        switch columnCount {
        case ...1: return 28
        case 2 ... 3: return 20
        case 4 ... 5: return 14
        default: return 8
        }
    }

    /// Le compteur d'items à côté du titre disparaît en vue dense, pour épurer.
    private var showsSectionCount: Bool { columnCount <= 5 }

    private func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func hapticSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @ViewBuilder
    private var albumPickerContent: some View {
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

    // MARK: - Pinch-to-zoom (densité de la grille)

    /// Sonde de pinch posée dans le contenu de la `ScrollView`. Elle branche un
    /// `UIPinchGestureRecognizer` sur l'`UIScrollView` sous-jacent — seule façon
    /// fiable, sur iOS 16, d'obtenir le point médian des deux doigts (l'épicentre
    /// du geste) ; `MagnificationGesture` ne l'expose pas.
    private func pinchDetector(scrollProxy: ScrollViewProxy) -> some View {
        PinchZoomDetector(
            onBegan: { handlePinchBegan($0) },
            onChanged: { handlePinchChanged($0) },
            onEnded: { handlePinchEnded($0, scrollProxy: scrollProxy) }
        )
    }

    /// Début du pinch : on fige l'épicentre. Le point médian des deux doigts
    /// devient l'ancre du `.scaleEffect` (le contenu dessous restera fixe) et on
    /// mémorise la tile visée pour recentrer le scroll après un éventuel snap.
    private func handlePinchBegan(_ sample: PinchSample) {
        // Pas de pinch pendant un drag-select : un second doigt accidentel ne
        // doit pas redimensionner la grille pendant l'affinage d'une sélection.
        guard dragSelectAnchorId == nil else { return }
        isPinching = true
        gestureScale = 1.0
        pinchArmedForCommit = false
        gestureAnchor = UnitPoint(x: 0.5, y: sample.anchorUnitY)
        pinchAnchorViewportFraction = sample.viewportFraction
        pinchAnchorTileId = tileFrames
            .first(where: { $0.value.contains(sample.globalLocation) })?.key
    }

    /// Glissement des doigts : on applique l'échelle homothétique en direct et
    /// on joue un petit cran haptique au franchissement du seuil de bascule —
    /// le geste « prépare » visuellement la transition vers le niveau voisin.
    private func handlePinchChanged(_ sample: PinchSample) {
        guard isPinching else { return }
        let scale = clampedGestureScale(sample.scale)
        gestureScale = scale
        let armed = commitTarget(for: scale) != zoomLevelIndex
        if armed != pinchArmedForCommit {
            pinchArmedForCommit = armed
            if armed { hapticFeedback(.soft) }
        }
    }

    /// Fin du pinch : si le seuil a été franchi, on se fige sur le niveau voisin
    /// et on recentre le scroll sur l'épicentre ; sinon ressort inverse qui
    /// ramène la grille à son état initial exact.
    private func handlePinchEnded(_ sample: PinchSample, scrollProxy: ScrollViewProxy) {
        guard isPinching else { return }
        isPinching = false
        pinchArmedForCommit = false

        let finalScale = clampedGestureScale(sample.scale)
        let target = commitTarget(for: finalScale)
        let settle = Animation.spring(response: 0.34, dampingFraction: 0.82)

        if target != zoomLevelIndex {
            hapticFeedback(.rigid)
            let anchorId = pinchAnchorTileId
            let viewportFraction = pinchAnchorViewportFraction
            // Le changement de niveau et la remise à l'échelle 1.0 sont animés
            // ensemble : la taille rendue (layout × échelle) varie de façon
            // monotone, donc la bascule se lit comme un zoom continu sans à-coup.
            withAnimation(settle) {
                zoomLevelIndex = target
                gestureScale = 1.0
                // Recentrage : la tile visée au début du geste revient sous
                // l'épicentre malgré la réorganisation complète de la grille.
                if let anchorId {
                    scrollProxy.scrollTo(
                        anchorId,
                        anchor: UnitPoint(x: 0.5, y: viewportFraction)
                    )
                }
            }
        } else {
            // Seuil non atteint : ressort inverse, la grille reprend son état exact.
            withAnimation(settle) { gestureScale = 1.0 }
        }
        pinchAnchorTileId = nil
    }

    /// Niveau de densité visé pour une échelle donnée. Renvoie le niveau courant
    /// quand aucun seuil n'est franchi (ou qu'il n'existe pas de cran au-delà).
    private func commitTarget(for scale: CGFloat) -> Int {
        let lastIndex = Self.zoomLevels.count - 1
        if scale >= zoomInCommitThreshold, zoomLevelIndex > 0 {
            return zoomLevelIndex - 1
        }
        if scale <= zoomOutCommitThreshold, zoomLevelIndex < lastIndex {
            return zoomLevelIndex + 1
        }
        return zoomLevelIndex
    }

    /// Borne l'échelle du geste. Aux niveaux extrêmes, écarter ou pincer « dans
    /// le vide » ne donne qu'un léger jeu élastique signalant la butée.
    private func clampedGestureScale(_ raw: CGFloat) -> CGFloat {
        let canZoomIn = zoomLevelIndex > 0
        let canZoomOut = zoomLevelIndex < Self.zoomLevels.count - 1
        let upperLimit: CGFloat = canZoomIn ? 2.4 : 1.08
        let lowerLimit: CGFloat = canZoomOut ? 0.45 : 0.94
        return min(max(raw, lowerLimit), upperLimit)
    }

    // MARK: - Drag-to-select (long-press → drag continu sans relever)

    /// Liste plate des ids dans l'ordre d'affichage. Sert à calculer la "range
    /// chronologique" entre l'anchor et la tile sous le doigt pendant le drag.
    private var orderedTileIds: [String] {
        guard case .ready(_, let sections) = viewModel.state else { return [] }
        return sections.flatMap { $0.items.map(\.id) }
    }

    /// Geste maître : `LongPress(0.5s).sequenced(before: Drag)` au niveau ScrollView.
    /// `.simultaneousGesture` permet la coexistence avec le pan natif d'UIScrollView,
    /// d'où le scroll continue de fonctionner pendant les 500ms d'attente. Quand le
    /// long-press confirme (doigt resté stable assez longtemps), la phase drag se
    /// met en place et notre handler hit-teste la tile sous le doigt pour l'utiliser
    /// comme anchor — puis chaque mouvement étend ou rétracte la plage.
    private func dragSelectMasterGesture(scrollProxy: ScrollViewProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 30)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                if case .second(true, let drag) = value, let drag {
                    handleDragChange(at: drag.location, scrollProxy: scrollProxy)
                }
            }
            .onEnded { value in
                if case .second(true, _) = value {
                    handleDragEnded()
                }
            }
    }

    /// Appelé pour chaque événement de la phase drag. Le premier appel matérialise
    /// l'ancrage : on hit-teste pour trouver la tile sous le doigt à ce moment-là,
    /// haptique de confirmation, snapshot de la sélection courante. Les suivants
    /// étendent la plage `[anchor, current]` dans l'ordre chronologique.
    private func handleDragChange(at globalLocation: CGPoint, scrollProxy: ScrollViewProxy) {
        if dragSelectAnchorId == nil {
            // Premier événement = long-press confirmé. Anchor = tile sous le doigt
            // au moment exact de la confirmation. Si on est sur un espace vide
            // (entre tiles, header), on ne fait rien et la gesture se terminera
            // en no-op au relâchement.
            guard let hitTile = tileFrames.first(where: { $0.value.contains(globalLocation) })?.key else {
                return
            }
            hapticFeedback(.medium)
            dragSelectAnchorId = hitTile
            dragSelectInitialSelection = viewModel.selectionManager.selectedIds
            viewModel.beginSelectionMode(itemId: hitTile)
            lastDragLocation = globalLocation
            return
        }
        lastDragLocation = globalLocation
        updateRangeSelection(at: globalLocation)
        evaluateAutoScroll(at: globalLocation, scrollProxy: scrollProxy)
    }

    private func handleDragEnded() {
        dragSelectAnchorId = nil
        dragSelectInitialSelection = []
        lastDragLocation = nil
        stopAutoScroll()
    }

    /// Recalcule `selection = snapshot ∪ [anchor, current]` à partir de la
    /// position globale du doigt. Si aucune tile n'est sous le doigt (drag
    /// dans une zone vide), on conserve la dernière sélection.
    private func updateRangeSelection(at globalLocation: CGPoint) {
        guard let anchor = dragSelectAnchorId else { return }
        let ordered = orderedTileIds
        guard let anchorIdx = ordered.firstIndex(of: anchor) else { return }
        // Hit-test global : on cherche la tile contenant le point. Si rien, on
        // garde l'état précédent (utile sur les bords avant que la grille n'auto-scroll).
        guard let hitTile = tileFrames.first(where: { $0.value.contains(globalLocation) })?.key,
              let currentIdx = ordered.firstIndex(of: hitTile) else { return }
        let lo = min(anchorIdx, currentIdx)
        let hi = max(anchorIdx, currentIdx)
        let rangeIds = Set(ordered[lo ... hi])
        viewModel.setSelection(ids: dragSelectInitialSelection.union(rangeIds))
    }

    // MARK: Auto-scroll proportionnel

    /// Frame de référence pour évaluer les zones tampon de l'auto-scroll. On
    /// préfère le frame de la ScrollView (capté par PreferenceKey) ; si jamais
    /// celui-ci n'est pas encore disponible (race condition au tout premier
    /// drag-select), on tombe sur les bounds de l'écran principal pour ne
    /// jamais court-circuiter l'auto-scroll.
    private var autoScrollReferenceFrame: CGRect {
        if scrollViewGlobalFrame.height > 0 {
            return scrollViewGlobalFrame
        }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let bounds = scene.windows.first(where: { $0.isKeyWindow })?.bounds {
            return bounds
        }
        return UIScreen.main.bounds
    }

    /// Évalue si le doigt est dans la zone tampon haut/bas (10% de la hauteur
    /// de référence) et démarre/met à jour le timer d'auto-scroll en conséquence.
    /// L'intensité est proportionnelle à la proximité du bord absolu :
    ///   • à l'entrée de la zone (90%/10%) → intensité 0 (1 row par tick lent)
    ///   • au bord absolu → intensité 1 (plusieurs rows par tick)
    /// La référence est `autoScrollReferenceFrame` (ScrollView + fallback écran).
    private func evaluateAutoScroll(at globalLocation: CGPoint, scrollProxy: ScrollViewProxy) {
        let frame = autoScrollReferenceFrame
        let edgeZone = frame.height * 0.1
        guard edgeZone > 0 else { return }
        let distTop = globalLocation.y - frame.minY
        let distBottom = frame.maxY - globalLocation.y

        if distTop < edgeZone {
            let intensity = max(0, min(1, 1 - (distTop / edgeZone)))
            startAutoScroll(direction: .up, intensity: intensity, scrollProxy: scrollProxy)
        } else if distBottom < edgeZone {
            let intensity = max(0, min(1, 1 - (distBottom / edgeZone)))
            startAutoScroll(direction: .down, intensity: intensity, scrollProxy: scrollProxy)
        } else {
            stopAutoScroll()
        }
    }

    private func startAutoScroll(direction: AutoScrollDirection, intensity: CGFloat, scrollProxy: ScrollViewProxy) {
        autoScrollDirection = direction
        autoScrollIntensity = intensity
        guard autoScrollTimer == nil else { return }
        // Tick à 30fps — granularité suffisante pour un défilement fluide sans
        // saturer le main thread (hit-test + scrollTo à chaque tick).
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                performAutoScrollStep(scrollProxy: scrollProxy)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollRowAccumulator = 0
    }

    /// Avance la position de scroll d'un nombre fractionnaire de rows par tick,
    /// proportionnel à l'intensité. Un accumulateur évite de perdre la fraction
    /// d'un tick au suivant à faible intensité. Après le scroll, on recalcule
    /// la sélection à partir de la dernière position connue du doigt — les
    /// tiles ont bougé sous le doigt, donc le hit-test donne un résultat différent.
    private func performAutoScrollStep(scrollProxy: ScrollViewProxy) {
        // Vitesse linéaire en points par seconde, échelonnée par l'intensité :
        //   • intensité 0 (entrée dans la zone tampon)  → 600 pt/s
        //   • intensité 1 (bord absolu de l'écran)      → 2500 pt/s
        // Le timer fire à 30Hz donc on convertit en pt/tick.
        let speedPointsPerSec = 600 + (2500 - 600) * autoScrollIntensity
        let deltaY = speedPointsPerSec / 30.0

        // Chemin UIKit (préféré) : `setContentOffset` fonctionne même quand
        // `isScrollEnabled = false`, contrairement à `scrollProxy.scrollTo` qui
        // peut être bloqué par `.scrollDisabled(...)` sur certaines versions iOS.
        if let scrollView = underlyingScrollView {
            let currentY = scrollView.contentOffset.y
            let topLimit = -scrollView.adjustedContentInset.top
            let bottomLimit = max(
                topLimit,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )

            let signedDelta = (autoScrollDirection == .down) ? deltaY : -deltaY
            let targetY = max(topLimit, min(bottomLimit, currentY + signedDelta))
            // Pas d'animation côté UIKit : c'est le timer 30Hz qui anime, chaque
            // tick fait un petit pas. animated:true créerait des animations qui
            // se chevauchent et causerait des saccades.
            if targetY != currentY {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
            } else {
                // On a atteint le bout : pas la peine de continuer à pomper.
                stopAutoScroll()
            }
        } else {
            // Fallback SwiftUI : `scrollProxy.scrollTo` avec la liste complète
            // `orderedTileIds`. Utilisé uniquement si l'introspection a échoué
            // (peu probable mais on garde la sécurité).
            let allIds = orderedTileIds
            guard !allIds.isEmpty else { return }
            let visibleSorted = tileFrames.sorted { $0.value.minY < $1.value.minY }
            guard !visibleSorted.isEmpty else { return }
            // 1 row par tick à intensité 0, 3 rows par tick à intensité max.
            let rowsPerTick = 1.0 + 2.0 * autoScrollIntensity
            autoScrollRowAccumulator += rowsPerTick
            guard autoScrollRowAccumulator >= 1 else { return }
            let wholeRows = Int(autoScrollRowAccumulator)
            autoScrollRowAccumulator -= CGFloat(wholeRows)
            let tilesToAdvance = wholeRows * columnCount

            switch autoScrollDirection {
            case .down:
                guard let key = visibleSorted.last?.key,
                      let idx = allIds.firstIndex(of: key) else { return }
                let targetIdx = min(idx + tilesToAdvance, allIds.count - 1)
                guard targetIdx > idx else { stopAutoScroll(); return }
                scrollProxy.scrollTo(allIds[targetIdx], anchor: .bottom)
            case .up:
                guard let key = visibleSorted.first?.key,
                      let idx = allIds.firstIndex(of: key) else { return }
                let targetIdx = max(idx - tilesToAdvance, 0)
                guard targetIdx < idx else { stopAutoScroll(); return }
                scrollProxy.scrollTo(allIds[targetIdx], anchor: .top)
            }
        }

        // Après le scroll, la grille a bougé sous le doigt : on relance la
        // sélection avec la dernière position connue pour étendre la plage
        // sur les tiles qui viennent d'apparaître sous le doigt.
        if let loc = lastDragLocation {
            updateRangeSelection(at: loc)
        }
    }
}

// MARK: - CircularSyncIndicator

/// Anneau de progression circulaire pour la toolbar. Trace un rail gris léger
/// + un arc accent qui se remplit avec la progression. Reste minuscule (18pt)
/// pour ne pas perturber la toolbar.
private struct CircularSyncIndicator: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                // Min 0.05 pour garder un repère visuel dès le début de la sync.
                .trim(from: 0, to: max(0.05, progress))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - SyncToastView

/// Toast in-app moderne style iOS 17 — pilule ultraThinMaterial, icône
/// colorée + libellé, ombre douce. Tappable (utilisé pour ouvrir le détail
/// d'erreur). Auto-dismiss géré côté `TimelineView`.
private struct SyncToastView: View {
    let toast: SyncToast
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(toast.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if toast.errorDetail != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        // Pas d'effet de scale par défaut au touch — on garde la sobriété.
        .contentShape(Capsule())
    }

    private var iconName: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.kind {
        case .success: return .green
        case .error: return .orange
        }
    }
}

// MARK: - GalleryTile

/// Internal (= module-scope) pour pouvoir être réutilisé dans `AlbumDetailView`
/// sans dupliquer le rendu. Hors timeline, les états `pendingUpload/uploading`
/// ne s'appliquent pas — passer `syncState = .synced` (ou `.cloudOnly`) côté
/// caller dans ce cas.
struct GalleryTile: View {
    let item: GalleryItem
    let size: CGFloat
    let namespace: Namespace.ID
    let isSelected: Bool
    let onTap: () -> Void
    /// Callback du tap sur le badge orange (échec d'upload).
    let onShowFailureReason: (String, String) -> Void
    /// Callback du tap sur le badge rouge (échec de suppression). `(fileId, reason)`.
    let onShowDeletionFailure: (String, String) -> Void

    /// Indique si l'item est en cours de suppression — sert à atténuer la tile
    /// pour signaler "ce contenu est en train de disparaître". Voile blanc à
    /// 50% (vs 30% noir pour selection) pour rester distinguable visuellement.
    private var isDeletingState: Bool {
        switch item.syncState {
        case .deletionPending, .deleting, .deletionFailed:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: size, height: size)
                .matchedGeometryEffect(id: matchedId, in: namespace)

            thumbnail

            if isSelected {
                Color.black.opacity(0.3)
            }
            // Voile de "deletion in progress" — au-dessus du voile selection pour
            // que la photo soit clairement marquée même si elle est sélectionnée.
            if isDeletingState {
                Color(uiColor: .systemBackground).opacity(0.55)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TileFramePreferenceKey.self,
                    value: [item.id: geo.frame(in: .global)]
                )
            }
        )
        .onTapGesture(perform: onTap)
        // Pas de gesture supplémentaire ici : tout long-press/drag-select est géré
        // au niveau de la ScrollView pour éviter de bloquer le scroll natif sur les
        // tiles. Le hit-testing se fait via `TileFramePreferenceKey` côté parent.
        .overlay(alignment: .topTrailing) {
            if item.isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
            }
        }
        .overlay(alignment: .topLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            SyncBadge(state: item.syncState, onFailureTap: badgeTapHandler)
        }
    }

    /// `nil` quand l'item n'est pas en échec ou n'a pas de raison à afficher —
    /// le badge reste alors inerte. Capturé par `SyncBadge` qui décide d'afficher
    /// un `Button` ou un `Image` simple.
    /// Gère les deux types d'échec (upload + deletion) : on dispatche sur l'état
    /// de l'item au moment du tap.
    private var badgeTapHandler: (() -> Void)? {
        if case .uploadFailed(let reason) = item.syncState,
           !reason.isEmpty,
           let localId = item.localAssetIdentifier {
            return { onShowFailureReason(localId, reason) }
        }
        if case .deletionFailed(let reason) = item.syncState,
           !reason.isEmpty,
           let fileId = item.cloudFileId {
            return { onShowDeletionFailure(fileId, reason) }
        }
        return nil
    }

    private var matchedId: String {
        if let fileId = item.cloudFileId { return "photo-\(fileId)" }
        return "local-\(item.id)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let localId = item.localAssetIdentifier {
            LocalThumbnail(localIdentifier: localId, size: size)
        } else if let driveId = item.cloudDriveId, let fileId = item.cloudFileId {
            CloudThumbnail(driveId: driveId, fileId: fileId, size: size)
        }
    }
}

// MARK: - LocalThumbnail

struct LocalThumbnail: View {
    let localIdentifier: String
    let size: CGFloat
    @StateObject private var loader: LocalThumbnailLoader

    init(localIdentifier: String, size: CGFloat) {
        self.localIdentifier = localIdentifier
        self.size = size
        let scale = UIScreen.main.scale
        _loader = StateObject(wrappedValue: LocalThumbnailLoader(
            localIdentifier: localIdentifier,
            targetSize: CGSize(width: size * scale, height: size * scale)
        ))
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                ThumbnailPlaceholder(size: size)
            }
        }
        .onAppear { loader.load() }
    }
}

// MARK: - ThumbnailPlaceholder

/// Remplaçant neutre affiché tant qu'une vignette n'est pas chargée (ou si le
/// chargement a définitivement échoué). Gris adaptatif light/dark — évite le
/// rendu « tuile blanche » qui donnait l'impression d'un bug.
struct ThumbnailPlaceholder: View {
    let size: CGFloat

    var body: some View {
        Color(uiColor: .secondarySystemFill)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: size * 0.22, weight: .regular))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            )
    }
}

// MARK: - CloudThumbnail

struct CloudThumbnail: View {
    let driveId: Int
    let fileId: String
    let size: CGFloat
    @StateObject private var loader: ThumbnailLoader

    init(driveId: Int, fileId: String, size: CGFloat) {
        self.driveId = driveId
        self.fileId = fileId
        self.size = size
        _loader = StateObject(wrappedValue: ThumbnailLoader(driveId: driveId, fileId: fileId))
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                ThumbnailPlaceholder(size: size)
            }
        }
        .task { await loader.load() }
    }
}

// MARK: - ScrollViewIntrospector

/// Sonde invisible qui remonte la chaîne `superview` pour retrouver le
/// `UIScrollView` UIKit sous-jacent à la SwiftUI `ScrollView` parente. Sert à
/// piloter l'auto-scroll en `setContentOffset(_:animated:)` (qui fonctionne
/// même quand `isScrollEnabled = false`), au lieu de passer par
/// `ScrollViewProxy.scrollTo` qui est bloqué par `.scrollDisabled(...)` sur
/// plusieurs versions d'iOS.
///
/// L'introspection est faite après un cycle de layout (DispatchQueue.main.async)
/// car la view UIKit n'est pas encore montée à l'instant de `makeUIView`.
private struct ScrollViewIntrospector: UIViewRepresentable {
    let onFound: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView() {
                onFound(scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // En cas de re-layout / changement de hiérarchie, on retente la
        // résolution (idempotent côté appelant grâce au check d'identité).
        DispatchQueue.main.async {
            if let scrollView = uiView.enclosingScrollView() {
                onFound(scrollView)
            }
        }
    }
}

private extension UIView {
    /// Remonte la chaîne `superview` jusqu'à trouver un `UIScrollView`.
    /// `nil` si aucun ancêtre n'en est un (cas pathologique d'une vue détachée).
    func enclosingScrollView() -> UIScrollView? {
        var node: UIView? = superview
        while let current = node {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            node = current.superview
        }
        return nil
    }
}

// MARK: - PinchZoomDetector

/// Échantillon d'un événement de pinch, déjà projeté dans des repères
/// directement exploitables par la grille — l'appelant n'a aucune conversion de
/// coordonnées à faire.
struct PinchSample {
    /// Facteur d'échelle cumulé depuis le début du geste (1.0 au tout début).
    let scale: CGFloat
    /// Position verticale de l'épicentre dans le contenu, normalisée [0, 1] —
    /// utilisable telle quelle comme ancre `y` d'un `.scaleEffect`.
    let anchorUnitY: CGFloat
    /// Position verticale de l'épicentre dans le viewport, normalisée [0, 1].
    let viewportFraction: CGFloat
    /// Point médian des deux doigts en coordonnées globales (fenêtre) — pour
    /// hit-tester la tile située sous l'épicentre.
    let globalLocation: CGPoint
}

/// Sonde invisible qui branche un `UIPinchGestureRecognizer` sur l'`UIScrollView`
/// sous-jacent à la `ScrollView` SwiftUI parente. C'est le seul moyen fiable, sur
/// iOS 16, d'obtenir le point médian des deux doigts (l'épicentre du geste) :
/// `MagnificationGesture` ne l'expose pas, et `MagnifyGesture` (qui le ferait via
/// `startAnchor`) n'existe qu'à partir d'iOS 17.
///
/// Le recognizer est posé en reconnaissance simultanée pour cohabiter avec le pan
/// natif et les gestes SwiftUI. Le pan natif est restreint à un seul doigt, si
/// bien qu'un pinch (deux doigts) ne déclenche jamais de défilement parasite.
private struct PinchZoomDetector: UIViewRepresentable {
    let onBegan: (PinchSample) -> Void
    let onChanged: (PinchSample) -> Void
    let onEnded: (PinchSample) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        // La vue n'est pas encore montée dans la hiérarchie à cet instant —
        // on diffère la résolution de l'`UIScrollView` d'un cycle de layout.
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView() {
                context.coordinator.attach(to: scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Rafraîchit les closures pour que le recognizer appelle toujours la
        // dernière version (capturant l'état SwiftUI courant).
        context.coordinator.parent = self
        if context.coordinator.scrollView == nil {
            DispatchQueue.main.async {
                if let scrollView = uiView.enclosingScrollView() {
                    context.coordinator.attach(to: scrollView)
                }
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PinchZoomDetector
        weak var scrollView: UIScrollView?

        init(_ parent: PinchZoomDetector) {
            self.parent = parent
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView == nil else { return }
            self.scrollView = scrollView
            // Le pan natif ne réagit plus qu'à un doigt : un pinch (deux doigts)
            // ne provoque donc jamais de défilement parasite pendant le zoom.
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handlePinch(_:))
            )
            pinch.delegate = self
            scrollView.addGestureRecognizer(pinch)
        }

        @objc
        private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView else { return }
            let viewportHeight = scrollView.bounds.height
            let contentHeight = scrollView.contentSize.height
            guard viewportHeight > 0, contentHeight > 0 else { return }

            // `location(in: scrollView)` est déjà en coordonnées de contenu :
            // l'origine du repère d'un `UIScrollView` suit son `contentOffset`.
            let contentY = recognizer.location(in: scrollView).y
            let offsetY = scrollView.contentOffset.y
            let sample = PinchSample(
                scale: recognizer.scale,
                anchorUnitY: min(max(contentY / contentHeight, 0), 1),
                viewportFraction: min(max((contentY - offsetY) / viewportHeight, 0), 1),
                globalLocation: recognizer.location(in: nil)
            )

            switch recognizer.state {
            case .began:
                parent.onBegan(sample)
            case .changed:
                parent.onChanged(sample)
            case .ended, .cancelled, .failed:
                parent.onEnded(sample)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
