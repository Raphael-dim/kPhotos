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

public struct FullscreenMediaView: View {
    @StateObject private var actionsVM = ViewerActionsViewModel()
    private let media: [ViewerMedia]
    private let onClose: () -> Void
    private let onCurrentMediaChange: (String) -> Void
    private let namespace: Namespace.ID
    @State private var currentIndex: Int
    @State private var showControls = true
    @State private var showDeleteConfirm = false
    @State private var showAlbumPicker = false
    @State private var showInfo = false
    @State private var downloadToast: DownloadToast?

    // États gestuels du viewer.
    // `dragOffset`     : translation verticale du swipe-to-dismiss (suit le doigt en Y).
    // `horizontalDrag` : translation horizontale de la pagination média en cours.
    // `gestureAxis`    : axe verrouillé pour le geste courant. Décidé au premier
    //                    mouvement franc puis figé jusqu'au relâchement — un geste
    //                    est SOIT une pagination horizontale SOIT un swipe-to-dismiss
    //                    vertical, jamais les deux. Ce verrou exclusif garantit
    //                    qu'un swipe vers le bas ne laisse jamais apparaître le
    //                    média voisin.
    // `zoomStates`     : zoom de chaque page (clé = index). Le geste est désactivé
    //                    quand la page courante est zoomée pour laisser le pan
    //                    UIKit de l'UIScrollView gérer le déplacement intra-photo.
    @State private var dragOffset: CGSize = .zero
    @State private var horizontalDrag: CGFloat = 0
    @State private var gestureAxis: Axis?
    @State private var zoomStates: [Int: Bool] = [:]

    public init(
        media: [ViewerMedia],
        initialIndex: Int,
        namespace: Namespace.ID,
        onCurrentMediaChange: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.media = media
        self._currentIndex = State(initialValue: initialIndex)
        self.onClose = onClose
        self.onCurrentMediaChange = onCurrentMediaChange
        self.namespace = namespace
    }

    private var currentMedia: ViewerMedia { media[currentIndex] }

    /// Indique si l'action courante peut s'appliquer à kDrive (delete, album).
    /// Pour un média local-only, ces actions sont désactivées car elles n'ont
    /// aucun sens (la photo n'est pas sur le drive).
    private var canPerformCloudActions: Bool { currentMedia.isCloudBacked }

    /// Progression normalisée du swipe-to-dismiss (0 = repos, 1 = seuil dismiss atteint).
    private var dragProgress: Double {
        let maxDistance: CGFloat = 250
        return min(1, max(0, Double(dragOffset.height) / Double(maxDistance)))
    }

    private var isCurrentPageZoomed: Bool {
        zoomStates[currentIndex] ?? false
    }

    /// Fenêtre des pages réellement montées : la page courante et ses deux
    /// voisines immédiates. Évite d'instancier tout le tableau `media` (galeries
    /// de plusieurs milliers d'éléments) tout en gardant les voisines préchargées
    /// pour une pagination instantanée.
    private var windowIndices: [Int] {
        let lower = max(0, currentIndex - 1)
        let upper = min(media.count - 1, currentIndex + 1)
        return Array(lower ... upper)
    }

    public var body: some View {
        // `GeometryReader` racine : seul endroit où la safe area de l'écran est
        // lisible. Le pager interne l'ignore (`ignoresSafeArea`), donc on la
        // capture ici et on la propage aux pages pour encadrer le lecteur vidéo.
        GeometryReader { proxy in
            content(safeArea: proxy.safeAreaInsets)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isCurrentPageZoomed)
        .onChange(of: currentIndex) { _ in onCurrentMediaChange(currentMedia.id) }
        .mediaViewerTransition(id: currentMedia.id, in: namespace)
    }

    private func content(safeArea: EdgeInsets) -> some View {
        ZStack {
            // Fond noir qui fade vers transparent au fur et à mesure du drag.
            // Avec `.presentationBackground(.clear)` sur le cover, le fade révèle
            // la galerie située en arrière-plan (effet iOS Photos / Google Photos).
            Color.black
                .opacity(1 - dragProgress * 0.95)
                .ignoresSafeArea()

            // Pager maison. Le `GeometryReader` interne ignore la safe area
            // pour mesurer la taille plein écran ; le geste unifié est attaché
            // ici, sur les pages elles-mêmes.
            GeometryReader { fullProxy in
                interactivePager(size: fullProxy.size, safeArea: safeArea)
            }
            .ignoresSafeArea()
            // Le pager suit le doigt 1:1 en Y, atténué en X. Le scale léger
            // (~12% au seuil) reproduit l'effet de l'app Photos.
            .offset(dragOffset)
            .scaleEffect(1 - CGFloat(dragProgress) * 0.12)

            // Video taps belong to native playback controls; keep app actions visible.
            if showControls || currentMedia.isVideo {
                controlsOverlay
                    // Les contrôles disparaissent plus vite que le fond pour
                    // dégager la photo dès qu'on amorce le swipe.
                    .opacity(max(0, 1 - dragProgress * 2.5))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .overlay(alignment: .bottom) {
            if let toast = downloadToast {
                DownloadToastBanner(toast: toast)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: downloadToast != nil)
        // Fond modal transparent — sans ça, fade vers transparent ne laisserait
        // voir qu'un autre noir système.
        .presentationBackground(.clear)
        .confirmationDialog(
            L10n.Viewer.deleteConfirmTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.Common.delete, role: .destructive) {
                Task {
                    guard case .cloud(let snapshot) = currentMedia else { return }
                    if await actionsVM.delete(photo: snapshot) { onClose() }
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Viewer.deleteConfirmMessage)
        }
        .sheet(isPresented: $showAlbumPicker) {
            albumPickerSheet
        }
        .sheet(isPresented: $showInfo) {
            photoInfoSheet
        }
    }

    /// Pile de pages média positionnées côte à côte. Seules les pages de
    /// `windowIndices` sont montées ; chacune est décalée d'une largeur d'écran
    /// par rapport à la page courante, `horizontalDrag` ajoutant le suivi du
    /// doigt pendant une pagination. `.clipped()` garantit qu'aucune page
    /// voisine ne déborde — y compris pendant le scale du swipe-to-dismiss.
    private func pager(size: CGSize, safeArea: EdgeInsets) -> some View {
        ZStack {
            ForEach(windowIndices, id: \.self) { index in
                MediaPageView(
                    media: media[index],
                    isActive: index == currentIndex,
                    safeArea: safeArea,
                    onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    },
                    onZoomChange: { isZoomed in
                        zoomStates[index] = isZoomed
                    }
                )
                .frame(width: size.width, height: size.height)
                .offset(x: CGFloat(index - currentIndex) * size.width + horizontalDrag)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private func interactivePager(size: CGSize, safeArea: EdgeInsets) -> some View {
        if #available(iOS 18.0, *) {
            pager(size: size, safeArea: safeArea)
                .gesture(ViewerPagingGesture(
                    isEnabled: !isCurrentPageZoomed,
                    onChange: updateHorizontalDrag,
                    onEnd: { translation, predicted in
                        finishHorizontalDrag(translation: translation, predicted: predicted, width: size.width)
                    },
                    onCancel: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { horizontalDrag = 0 }
                    }
                ))
        } else {
            pager(size: size, safeArea: safeArea)
                .simultaneousGesture(pagerGesture(width: size.width))
        }
    }

    private func updateHorizontalDrag(_ translation: CGFloat) {
        let atFirst = currentIndex == 0 && translation > 0
        let atLast = currentIndex == media.count - 1 && translation < 0
        horizontalDrag = atFirst || atLast ? translation * 0.3 : translation
    }

    private func finishHorizontalDrag(translation: CGFloat, predicted: CGFloat, width: CGFloat) {
        var target = currentIndex
        if currentIndex < media.count - 1, translation < -width * 0.25 || predicted < -width * 0.5 {
            target += 1
        } else if currentIndex > 0, translation > width * 0.25 || predicted > width * 0.5 {
            target -= 1
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            currentIndex = target
            horizontalDrag = 0
        }
    }

    /// Un seul `DragGesture` arbitre les deux interactions qui, sinon, se
    /// disputeraient le doigt :
    /// - au premier mouvement franc on verrouille un axe (`gestureAxis`) ;
    /// - axe horizontal → pagination média (page précédente / suivante) ;
    /// - axe vertical   → swipe-to-dismiss façon iOS Photos.
    ///
    /// L'axe est exclusif et figé jusqu'au relâchement : un swipe vers le bas
    /// ne déclenche donc jamais la pagination — aucun média voisin n'apparaît,
    /// aucun « rollback » horizontal. C'est tout l'intérêt d'avoir abandonné le
    /// `TabView`, dont le scroll interne tournait en parallèle du geste.
    ///
    /// Page zoomée → on cède la main au pan de l'UIScrollView interne.
    private func pagerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !isCurrentPageZoomed else { return }

                if gestureAxis == nil {
                    gestureAxis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal
                        : .vertical
                }
                guard let axis = gestureAxis else { return }

                switch axis {
                case .horizontal:
                    updateHorizontalDrag(value.translation.width)

                case .vertical:
                    // Suivi du doigt : 1:1 en Y descendant, atténué en X.
                    dragOffset = CGSize(
                        width: value.translation.width * 0.35,
                        height: max(0, value.translation.height)
                    )
                }
            }
            .onEnded { value in
                defer { gestureAxis = nil }
                guard !isCurrentPageZoomed, let axis = gestureAxis else { return }

                switch axis {
                case .horizontal:
                    finishHorizontalDrag(
                        translation: value.translation.width,
                        predicted: value.predictedEndTranslation.width,
                        width: width
                    )

                case .vertical:
                    // Dismiss si distance > 130pt OU vélocité prédite > 280pt,
                    // sinon retour à 0 avec un spring naturel.
                    let distance = value.translation.height
                    let predicted = value.predictedEndTranslation.height
                    if distance > 130 || predicted > 280 {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = .zero
                        }
                    }
                }
            }
    }
}

private extension FullscreenMediaView {
    @ViewBuilder private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
            Spacer()
            bottomBar
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            // Bouton retour — cercle glass autonome.
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .viewerControlStyle()
            .accessibilityLabel(L10n.Common.close)

            Spacer(minLength: 0)

            VStack(spacing: 3) {
                Text(pillDate(currentMedia.takenAt))
                    .font(.subheadline.weight(.semibold))
                ViewerLocationView(media: currentMedia)
                    .id(currentMedia.id)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassPill(in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            // Menu "..." — cercle glass autonome.
            Menu {
                Button {
                    showAlbumPicker = true
                } label: {
                    Label(L10n.Viewer.addToAlbum, systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(!canPerformCloudActions)

                Button {
                    downloadCurrentPhoto()
                } label: {
                    if actionsVM.isDownloading {
                        Label(L10n.Viewer.saveToLibrary, systemImage: "arrow.down.circle")
                    } else {
                        Label(L10n.Viewer.saveToLibrary, systemImage: "arrow.down.to.line")
                    }
                }
                .disabled(actionsVM.isDownloading || !canPerformCloudActions)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .viewerControlStyle()
            .accessibilityLabel(L10n.Common.more)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(action: downloadCurrentPhoto) {
                Group {
                    if actionsVM.isDownloading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 20))
                    }
                }
                .frame(width: 24, height: 24)
            }
            .viewerControlStyle()
            .accessibilityLabel(L10n.Viewer.saveToLibrary)
            .disabled(actionsVM.isDownloading || !canPerformCloudActions)

            Spacer()

            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20))
                    .frame(width: 24, height: 24)
            }
            .viewerControlStyle()
            .accessibilityLabel(L10n.Viewer.Info.title)

            Spacer()

            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .frame(width: 24, height: 24)
            }
            .viewerControlStyle()
            .accessibilityLabel(L10n.Viewer.delete)
            .disabled(!canPerformCloudActions)
        }
    }

    private func downloadCurrentPhoto() {
        Task {
            guard case .cloud(let snapshot) = currentMedia else { return }
            let success = await actionsVM.download(photo: snapshot)
            let toast: DownloadToast = success
                ? .success
                : .failure(actionsVM.errorMessage ?? L10n.Common.errorGeneric)
            withAnimation { downloadToast = toast }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { downloadToast = nil }
        }
    }

    private var albumPickerSheet: some View {
        NavigationStack {
            List {
                if actionsVM.albums.isEmpty {
                    Text(L10n.Viewer.albumsEmpty)
                        .foregroundStyle(.secondary)
                }
                ForEach(actionsVM.albums) { album in
                    Button {
                        Task {
                            guard case .cloud(let snapshot) = currentMedia else { return }
                            await actionsVM.addToAlbum(photo: snapshot, albumId: album.id)
                            showAlbumPicker = false
                        }
                    } label: {
                        HStack {
                            Text(album.name)
                            Spacer()
                            Text(L10n.Albums.photoCount(count: album.photoCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(L10n.Viewer.selectAlbumTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.cancel, role: .cancel) { showAlbumPicker = false }
                }
            }
            .task { await actionsVM.loadAlbums() }
        }
    }

    private var photoInfoSheet: some View {
        NavigationStack {
            PhotoInfoView(media: currentMedia)
                .navigationTitle(L10n.Viewer.Info.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.Common.done, role: .appClose) { showInfo = false }
                    }
                }
        }
    }

    private func pillDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE · HH:mm"
        return formatter.string(from: date).capitalized
    }
}
