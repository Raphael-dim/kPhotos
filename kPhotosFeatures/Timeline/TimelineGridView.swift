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
import kPhotosResources
import SwiftUI
import UIKit

struct TimelineGridActions {
    let onOpen: (GalleryItem) -> Void
    let onBackupFailure: (String, String) -> Void
    let onDeletionFailure: (String, String) -> Void
    let onShowBackup: () -> Void
    let onTitleChange: (String) -> Void
}

struct TimelineGridView: View {
    @ObservedObject private var viewModel: TimelineViewModel
    @ObservedObject private var interaction: TimelineGridInteraction
    let sections: [GallerySection]
    let viewerNamespace: Namespace.ID
    let viewerGalleryItemID: String?
    let isViewerPresented: Bool
    let actions: TimelineGridActions

    init(
        viewModel: TimelineViewModel,
        interaction: TimelineGridInteraction,
        sections: [GallerySection],
        namespace: Namespace.ID,
        viewerGalleryItemID: String?,
        isViewerPresented: Bool,
        actions: TimelineGridActions
    ) {
        self.viewModel = viewModel
        self.sections = sections
        self.viewerNamespace = namespace
        self.viewerGalleryItemID = viewerGalleryItemID
        self.isViewerPresented = isViewerPresented
        self.actions = actions
        self.interaction = interaction
    }

    var body: some View { sectionsList(sections) }

    private var activityButton: some View {
        TimelineLibraryStatus(viewModel: viewModel, onOpen: actions.onShowBackup)
    }

    private func sectionsList(_ sections: [GallerySection]) -> some View {
        GeometryReader { proxy in
            let gridSpacing: CGFloat = 3
            let available = proxy.size.width - (gridSpacing * CGFloat(interaction.columnCount - 1))
            // Plancher purement défensif — jamais atteint pour `zoomLevels` (max
            // 7 colonnes), il évite seulement une taille dégénérée si la largeur
            // disponible devenait nulle pendant une transition de layout.
            let tileSize = max(36, available / CGFloat(interaction.columnCount))

            // ScrollViewReader = pré-requis pour l'auto-scroll programmatique
            // pendant le drag-select aux bords (scrollTo(id, anchor:)).
            ScrollViewReader { scrollProxy in
                ZStack(alignment: .trailing) {
                    ScrollView {
                        scrollContent(sections: sections, tileSize: tileSize, gridSpacing: gridSpacing, scrollProxy: scrollProxy)
                            // Transformation homothétique du pinch, ancrée sur l'épicentre
                            // du geste : le contenu sous le point médian des doigts reste
                            // strictement fixe pendant tout le zoom (cf. PinchZoomDetector).
                            .scaleEffect(interaction.gestureScale, anchor: interaction.gestureAnchor)
                    }
                    .coordinateSpace(name: "timelineScroll")
                    // Le rail tactile dédié recouvre le bord droit et pilote ce même
                    // UIScrollView. L'indicateur natif trop étroit est masqué.
                    .scrollIndicators(.hidden)
                    // Pendant le drag-select on bloque le pan utilisateur — sinon
                    // tirer le doigt vers le bas ferait remonter la grille (sens
                    // naturel du pan), l'inverse de ce qu'on veut. L'auto-scroll
                    // utilise `setContentOffset` via l'introspecteur, qui n'est
                    // PAS affecté par `scrollDisabled`.
                    .scrollDisabled(interaction.dragSelectAnchorId != nil)
                    // Le geste long-press + drag-to-select est posé UNE SEULE FOIS sur la
                    // ScrollView (pas par tile). C'est crucial pour le scroll : attacher un
                    // geste à chaque tile bloque les touches au niveau de la tile et
                    // empêche la ScrollView de voir le pan. Ici, en simultaneousGesture sur
                    // la ScrollView elle-même, on coexiste avec le pan natif d'UIScrollView.
                    // Pendant les 500ms d'attente, si le doigt glisse, le long-press
                    // se cancel et le scroll prend naturellement. La tile sous le doigt
                    // est résolue via hit-test sur `interaction.tileFrames` (publiés par chaque tile
                    // via PreferenceKey).
                    .simultaneousGesture(dragSelectionGesture(scrollProxy: scrollProxy))
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
                        updateNavigationTitle(positions: positions)
                    }
                    .onPreferenceChange(TileFramePreferenceKey.self) { frames in
                        interaction.tileFrames = frames
                    }
                    .onPreferenceChange(ScrollFramePreferenceKey.self) { frame in
                        interaction.scrollViewGlobalFrame = frame
                    }
                    .onChange(of: viewerGalleryItemID) { itemID in
                        guard let itemID else { return }
                        let frame = interaction.tileFrames[itemID] ?? .zero
                        if frame.isEmpty || !interaction.scrollViewGlobalFrame.contains(frame) {
                            // Mount the current thumbnail before the interactive return transition begins.
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { scrollProxy.scrollTo(itemID, anchor: .center) }
                        }
                    }
                    .onAppear { interaction.scrollViewGlobalFrame = proxy.frame(in: .global) }
                    .onDisappear {
                        interaction.stopAutoScroll()
                        if !isViewerPresented { interaction.scrollViewGlobalFrame = .zero }
                    }
                    TimelineFastScroller(scrollView: interaction.underlyingScrollView)
                        .frame(width: 44)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func updateNavigationTitle(positions: [String: CGFloat]) {
        let threshold: CGFloat = -90
        if let current = positions
            .filter({ $0.value < threshold })
            .max(by: { $0.value < $1.value }) {
            actions.onTitleChange(current.key)
        } else {
            actions.onTitleChange(L10n.Timeline.title)
        }
    }

    private func scrollContent(
        sections: [GallerySection], tileSize: CGFloat, gridSpacing: CGFloat, scrollProxy: ScrollViewProxy
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: sectionSpacing) {
            activityButton
                .padding(.horizontal, 20)

            ForEach(sections, id: \.id) { section in
                sectionRow(section, tileSize: tileSize, gridSpacing: gridSpacing)
            }
        }
        .padding(.vertical, 16)
        .background(alignment: .topLeading) {
            // Probes stay inside the scroll hierarchy without taking space between rows.
            ScrollViewIntrospector { scrollView in
                if interaction
                    .underlyingScrollView !== scrollView { interaction.underlyingScrollView = scrollView }
            }
            .frame(width: 0, height: 0)
            pinchDetector(scrollProxy: scrollProxy)
                .frame(width: 0, height: 0)
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
                columns: gridColumns(count: interaction.columnCount, spacing: gridSpacing),
                spacing: gridSpacing
            ) {
                ForEach(section.items) { item in
                    GalleryTile(
                        item: item,
                        size: tileSize,
                        namespace: viewerNamespace,
                        isSelected: viewModel.selectionManager.isSelected(item.id),
                        onTap: {
                            guard interaction.dragSelectAnchorId == nil else { return }
                            actions.onOpen(item)
                        },
                        onShowFailureReason: actions.onBackupFailure,
                        onShowDeletionFailure: actions.onDeletionFailure
                    )
                    .environment(
                        \.loadsCloudThumbnail,
                        (interaction.tileFrames[item.id] ?? .zero).intersects(interaction.scrollViewGlobalFrame.insetBy(
                            dx: 0,
                            dy: -tileSize * 2
                        ))
                    )
                    .environment(
                        \.cloudThumbnailPriority,
                        (interaction.tileFrames[item.id] ?? .zero).intersects(interaction.scrollViewGlobalFrame) ? 2 : 1
                    )
                }
            }
        }
    }

    private static let sectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static func sectionTitle(for section: GallerySection) -> String {
        var components = DateComponents()
        components.year = section.year
        components.month = section.month
        let date = Calendar.iso8601.date(from: components) ?? Date()
        return sectionDateFormatter.string(from: date).capitalized
    }

    private func gridColumns(count: Int, spacing: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    /// Police du titre de section — imposante en grand format, compacte en vue
    /// dense : l'en-tête de date « se range » à mesure que la grille se densifie.
    private var sectionTitleFont: Font {
        switch interaction.columnCount {
        case ...1: .title.weight(.bold)
        case 2 ... 3: .title3.weight(.semibold)
        case 4 ... 5: .subheadline.weight(.semibold)
        default: .caption.weight(.bold)
        }
    }

    /// Espacement vertical entre sections — se resserre quand la grille se densifie.
    private var sectionSpacing: CGFloat {
        switch interaction.columnCount {
        case ...1: 28
        case 2 ... 3: 20
        case 4 ... 5: 14
        default: 8
        }
    }

    /// Le compteur d'items à côté du titre disparaît en vue dense, pour épurer.
    private var showsSectionCount: Bool { interaction.columnCount <= 5 }

    private func pinchDetector(scrollProxy: ScrollViewProxy) -> some View {
        PinchZoomDetector(
            onBegan: { interaction.handlePinchBegan($0) },
            onChanged: { interaction.handlePinchChanged($0) },
            onEnded: { interaction.handlePinchEnded($0, scrollProxy: scrollProxy) }
        )
    }

    private func dragSelectionGesture(scrollProxy: ScrollViewProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 30)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                if case .second(true, let drag) = value, let drag {
                    interaction.handleDragChange(at: drag.location, scrollProxy: scrollProxy)
                }
            }
            .onEnded { value in
                if case .second(true, _) = value {
                    interaction.handleDragEnded()
                }
            }
    }
}
