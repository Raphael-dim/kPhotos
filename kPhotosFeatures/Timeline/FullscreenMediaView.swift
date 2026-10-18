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

import AVFoundation
import AVKit
import CoreLocation
import ImageIO
import kPhotosCore
import kPhotosCoreUI
import kPhotosResources
import MapKit
import Photos
import SwiftUI
import UIKit

// MARK: - FullscreenMediaView

public struct FullscreenMediaView: View {
    @StateObject private var actionsVM = ViewerActionsViewModel()
    private let media: [ViewerMedia]
    private let onClose: () -> Void
    @State private var currentIndex: Int
    @State private var showControls = true
    @State private var showDeleteConfirm = false
    @State private var showAlbumPicker = false
    @State private var showInfo = false
    @State private var downloadToast: DownloadToast? = nil

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
        namespace _: Namespace.ID,
        onClose: @escaping () -> Void
    ) {
        self.media = media
        self._currentIndex = State(initialValue: initialIndex)
        self.onClose = onClose
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
                pager(size: fullProxy.size, safeArea: safeArea)
                    .simultaneousGesture(pagerGesture(width: fullProxy.size.width))
            }
            .ignoresSafeArea()
            // Le pager suit le doigt 1:1 en Y, atténué en X. Le scale léger
            // (~12% au seuil) reproduit l'effet de l'app Photos.
            .offset(dragOffset)
            .scaleEffect(1 - CGFloat(dragProgress) * 0.12)

            // Sur une vidéo, la surcouche reste toujours visible : le lecteur
            // natif est encadré dans la bande libre entre nos deux barres, le
            // tap est réservé à ses propres contrôles — rien à masquer ici.
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

    // MARK: Pager

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

    // MARK: Geste unifié

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
                    var translationX = value.translation.width
                    // Résistance élastique aux extrémités (pas de page au-delà).
                    let atFirst = currentIndex == 0 && translationX > 0
                    let atLast = currentIndex == media.count - 1 && translationX < 0
                    if atFirst || atLast { translationX *= 0.3 }
                    horizontalDrag = translationX

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
                    // Bascule de page si la translation OU la vélocité prédite
                    // dépasse le seuil ; sinon retour élastique à la page courante.
                    let predicted = value.predictedEndTranslation.width
                    var target = currentIndex
                    if currentIndex < media.count - 1,
                       value.translation.width < -width * 0.25 || predicted < -width * 0.5 {
                        target += 1
                    } else if currentIndex > 0,
                              value.translation.width > width * 0.25 || predicted > width * 0.5 {
                        target -= 1
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        currentIndex = target
                        horizontalDrag = 0
                    }

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

    // MARK: Controls overlay

    /// Layout des contrôles façon iOS 26 Photos : trois pilules glass flottantes en
    /// haut (back / titre / menu) et trois pilules en bas (partager / actions / corbeille),
    /// au-dessus de la safe area. Plus de gradient noir plein écran : chaque contrôle
    /// est isolé, ce qui rend la photo en arrière-plan beaucoup plus visible.
    @ViewBuilder
    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
            Spacer()
            bottomBar
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            // Bouton retour — cercle glass autonome.
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .glassPill(in: Circle())

            Spacer(minLength: 0)

            // Pilule centrale : date du média (style natif iOS Photos).
            Text(pillDate(currentMedia.takenAt))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
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
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .glassPill(in: Circle())
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Partage — cercle autonome à gauche.
            Button(action: shareCurrentPhoto) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .glassPill(in: Circle())

            Spacer(minLength: 0)

            // Pilule centrale : favoris / info / édition.
            HStack(spacing: 0) {
                centerPillButton(systemImage: "heart") {
                    // Favoris — non implémenté (pas de concept dans kDrive)
                }
                centerPillButton(systemImage: "info.circle") {
                    showInfo = true
                }
                centerPillButton(systemImage: "slider.horizontal.3") {
                    // Retouche — non implémenté
                }
            }
            .glassPill(in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            // Corbeille — cercle autonome à droite.
            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .glassPill(in: Circle())
            .disabled(!canPerformCloudActions)
            .opacity(canPerformCloudActions ? 1 : 0.35)
        }
    }

    /// Bouton interne à la pilule centrale du bottomBar — taille fixe et padding
    /// réduit pour que les trois icônes tiennent dans une seule pilule compacte.
    private func centerPillButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 48)
                .contentShape(Rectangle())
        }
    }

    // MARK: Download

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

    // MARK: Share

    private func shareCurrentPhoto() {
        // Partage géré directement via UIActivityViewController sur la fenêtre active.
        // On ne peut pas utiliser ShareLink ici car le contenu est chargé à la demande.
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = windowScene.windows.first(where: { $0.isKeyWindow }),
            let rootVC = window.rootViewController else { return }

        let items: [Any] = [currentMedia.takenAt]
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        rootVC.present(vc, animated: true)
    }

    // MARK: Album picker

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.cancel) { showAlbumPicker = false }
                }
            }
            .task { await actionsVM.loadAlbums() }
        }
    }

    // MARK: Info sheet

    private var photoInfoSheet: some View {
        NavigationStack {
            PhotoInfoView(media: currentMedia)
                .navigationTitle(L10n.Viewer.Info.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.Common.done) { showInfo = false }
                    }
                }
        }
    }

    // MARK: Date helpers

    private func pillDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE · HH:mm"
        return formatter.string(from: date).capitalized
    }
}

// MARK: - DownloadToast

private enum DownloadToast: Equatable {
    case success
    /// Transporte le message localisé de l'erreur pour l'afficher directement.
    case failure(String)
}

private struct DownloadToastBanner: View {
    let toast: DownloadToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isSuccess ? .green : .red)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var isSuccess: Bool { toast == .success }

    private var message: String {
        switch toast {
        case .success: return L10n.Viewer.saveToLibrarySuccess
        case .failure(let msg): return msg
        }
    }
}

// MARK: - ExifMetadata

private struct ExifMetadata: Sendable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let make: String?
    let model: String?
    let lens: String?
    let fNumber: Double?
    let exposureTime: Double?
    let isoSpeed: Int?
    let focalLength: Double?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
}

// MARK: - PhotoLocation

/// Localisation résolue d'une photo. `placeName` est rempli en différé par le
/// reverse geocoding (peut rester nil si Apple ne renvoie rien d'utile, ex: en
/// pleine mer, ou si la requête CLGeocoder est rate-limitée).
private struct PhotoLocation: Equatable {
    let coordinate: CLLocationCoordinate2D
    var placeName: String?

    static func == (lhs: PhotoLocation, rhs: PhotoLocation) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.placeName == rhs.placeName
    }
}

private struct MapPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - LocationMapPreview

/// Mini-map non interactive centrée sur la coordonnée. Utilise l'API
/// `Map(coordinateRegion:annotationItems:)` qui marche en iOS 16+
/// (deprecated en 17 mais toujours fonctionnelle, et plus simple que de
/// versionner deux implémentations).
private struct LocationMapPreview: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(
            coordinateRegion: .constant(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )),
            interactionModes: [],
            annotationItems: [MapPin(coordinate: coordinate)]
        ) { pin in
            MapMarker(coordinate: pin.coordinate, tint: .red)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - PhotoInfoViewModel

@MainActor
private final class PhotoInfoViewModel: ObservableObject {
    @Published private(set) var fileDetail: RemoteFileDetailDTO?
    @Published private(set) var exif: ExifMetadata?
    @Published private(set) var location: PhotoLocation?
    @Published private(set) var isLoading = false

    private let photo: PhotoSnapshot
    @InjectService private var api: PhotoApiFetching

    init(photo: PhotoSnapshot) {
        self.photo = photo
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let driveId = photo.driveId
        let fileId = photo.fileId
        let cacheKey = "\(driveId)-\(fileId)"
        let localId = photo.localIdentifier

        async let detailTask = api.fileInfo(driveId: driveId, fileId: fileId)
        async let exifTask: ExifMetadata? = Self.extractExif(localIdentifier: localId, cacheKey: cacheKey)

        fileDetail = try? await detailTask
        let parsedExif = await exifTask
        exif = parsedExif

        // Localisation : PHAsset prioritaire (toujours présent côté iOS si la
        // photo vient du device), fallback sur EXIF GPS si le preview kDrive l'a
        // conservé.
        if let coord = Self.locationFromPHAsset(localIdentifier: localId) {
            location = PhotoLocation(coordinate: coord, placeName: nil)
        } else if let lat = parsedExif?.gpsLatitude, let lon = parsedExif?.gpsLongitude {
            location = PhotoLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                placeName: nil
            )
        }

        if let coord = location?.coordinate {
            let name = await Self.reverseGeocode(coord)
            // Re-check : la coord est toujours la même (l'utilisateur n'a pas
            // swipé vers une autre photo entre temps — protégé par @MainActor).
            if location?.coordinate.latitude == coord.latitude {
                location?.placeName = name
            }
        }
    }

    /// Lit `PHAsset.location` pour la photo si elle est encore présente dans la
    /// photothèque iOS. Renvoie nil si l'accès Photos n'a pas été accordé ou si
    /// l'asset n'existe plus localement (photo uploadée puis supprimée du device).
    private static func locationFromPHAsset(localIdentifier: String) -> CLLocationCoordinate2D? {
        guard !localIdentifier.isEmpty else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject, let loc = asset.location else { return nil }
        return loc.coordinate
    }

    /// Reverse-geocode une coordonnée vers une chaîne lisible "Lieu, Ville, Pays".
    /// CLGeocoder est rate-limité (50 req/min) — on encaisse silencieusement
    /// si Apple refuse.
    private static func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        let parts = [
            placemark.name, // ex: "Tour Eiffel" ou "5 Avenue Anatole France"
            placemark.locality, // ville
            placemark.country // pays
        ].compactMap { $0 }.filter { !$0.isEmpty }
        // Dédup : `name` peut déjà contenir la ville
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    /// Stratégie EXIF en cascade :
    /// 1. **PHAsset** — pour les photos encore présentes dans la photothèque iOS.
    ///    On obtient l'URL du fichier original via `requestContentEditingInput`
    ///    puis on lit juste les en-têtes EXIF avec `CGImageSourceCreateWithURL`
    ///    (lazy, ne charge pas l'image entière). C'est la même source qu'Apple
    ///    Photos — donne TOUS les tags (appareil, ISO, ouverture, GPS…).
    /// 2. **Cache disque du preview kDrive** — fallback si la photo n'est plus
    ///    sur le device. Les previews server-side sont souvent strippés de leur
    ///    EXIF, donc cette source ne retourne souvent que les dimensions.
    nonisolated static func extractExif(localIdentifier: String, cacheKey: String) async -> ExifMetadata? {
        if !localIdentifier.isEmpty,
           let fromAsset = await extractExifFromPHAsset(localIdentifier: localIdentifier) {
            return fromAsset
        }
        return await Task.detached(priority: .utility) {
            let data = PreviewCache.shared.diskData(forKey: cacheKey)
                ?? ThumbnailCache.shared.diskData(forKey: cacheKey)
            return data.flatMap(PhotoInfoViewModel.parseExif(from:))
        }.value
    }

    /// Demande à PhotoKit l'URL du fichier original (local-only, pas de download
    /// iCloud) et parse les EXIF avec ImageIO. `requestContentEditingInput`
    /// renvoie nil si l'asset n'est pas sur le device ou si l'accès Photos n'a
    /// pas été accordé.
    nonisolated static func extractExifFromPHAsset(localIdentifier: String) async -> ExifMetadata? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let url: URL? = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false // jamais de download iCloud — métadonnées only
            options.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.fullSizeImageURL)
            }
        }
        guard let url else { return nil }

        let cgOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, cgOptions),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return parseExif(properties: props)
    }

    nonisolated static func parseExif(from data: Data) -> ExifMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return parseExif(properties: props)
    }

    /// Cœur du parsing EXIF — partagé entre les sources Data et URL.
    nonisolated static func parseExif(properties props: [String: Any]) -> ExifMetadata? {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        // Les iPhone récents exposent les infos d'objectif via le bloc
        // ExifAux (lens make/model) ET ExifDictionary (LensModel). On regarde
        // les deux pour maximiser la couverture.
        let exifAux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]

        let make = tiff?[kCGImagePropertyTIFFMake as String] as? String
        let model = tiff?[kCGImagePropertyTIFFModel as String] as? String
        let lens = (exif?[kCGImagePropertyExifLensModel as String] as? String)
            ?? (exifAux?["LensModel"] as? String)
        let fNumber = exif?[kCGImagePropertyExifFNumber as String] as? Double
        let exposureTime = exif?[kCGImagePropertyExifExposureTime as String] as? Double
        let isoSpeed = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        let focalLength = exif?[kCGImagePropertyExifFocalLength as String] as? Double
        let pixelWidth = props[kCGImagePropertyPixelWidth as String] as? Int
        let pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int

        var gpsLat = gps?[kCGImagePropertyGPSLatitude as String] as? Double
        var gpsLon = gps?[kCGImagePropertyGPSLongitude as String] as? Double
        if let ref = gps?[kCGImagePropertyGPSLatitudeRef as String] as? String, ref == "S" { gpsLat = gpsLat.map { -$0 } }
        if let ref = gps?[kCGImagePropertyGPSLongitudeRef as String] as? String, ref == "W" { gpsLon = gpsLon.map { -$0 } }

        let hasData = make != nil || model != nil || lens != nil || fNumber != nil
            || pixelWidth != nil || gpsLat != nil
        guard hasData else { return nil }

        return ExifMetadata(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            make: make, model: model, lens: lens,
            fNumber: fNumber, exposureTime: exposureTime,
            isoSpeed: isoSpeed, focalLength: focalLength,
            gpsLatitude: gpsLat, gpsLongitude: gpsLon
        )
    }
}

// MARK: - InfoFormat (shared helpers)

/// Formatters partagés entre les vues d'info (cloud & local). Extraits ici pour
/// éviter de dupliquer la logique de présentation dans chaque vue concrète.
private enum InfoFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f.string(from: date)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func shutter(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        return "1/\(Int(round(1.0 / seconds))) s"
    }

    static func resolution(width: Int, height: Int) -> String {
        "\(width) × \(height) px"
    }
}

/// Ligne `label → value` standard utilisée par toutes les sections d'info.
private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Section "Localisation" partagée — mini-carte + reverse-geocoding + ouverture Plans.
/// Réutilisée par les vues d'info cloud et locale (DRY).
private struct LocationSection: View {
    let location: PhotoLocation

    var body: some View {
        Section(L10n.Viewer.Info.locationSection) {
            VStack(alignment: .leading, spacing: 8) {
                LocationMapPreview(coordinate: location.coordinate)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets())
                if let name = location.placeName, !name.isEmpty {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                }
                Text(String(
                    format: "%.5f, %.5f",
                    location.coordinate.latitude,
                    location.coordinate.longitude
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Button {
                    openInMaps()
                } label: {
                    Label(L10n.Viewer.Info.openInMaps, systemImage: "map")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: location.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = location.placeName ?? L10n.Viewer.Info.locationSection
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: location.coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        ])
    }
}

// MARK: - PhotoInfoView (dispatcher)

/// Point d'entrée unique : aiguille vers la fiche d'info adéquate selon que le
/// média est synchronisé sur kDrive ou présent uniquement dans la photothèque iOS.
private struct PhotoInfoView: View {
    let media: ViewerMedia

    var body: some View {
        switch media {
        case .cloud(let snapshot):
            CloudPhotoInfoView(photo: snapshot)
        case .local(let asset):
            LocalPhotoInfoView(asset: asset)
        }
    }
}

// MARK: - CloudPhotoInfoView

private struct CloudPhotoInfoView: View {
    let photo: PhotoSnapshot
    @StateObject private var vm: PhotoInfoViewModel

    init(photo: PhotoSnapshot) {
        self.photo = photo
        _vm = StateObject(wrappedValue: PhotoInfoViewModel(photo: photo))
    }

    var body: some View {
        List {
            fileSection
            dateSection
            if photo.isVideo { videoSection }
            if let exif = vm.exif, hasAnyCameraData(exif) { cameraSection(exif) }
            if let loc = vm.location { LocationSection(location: loc) }
            if let detail = vm.fileDetail { driveSection(detail) }
        }
        .task { await vm.load() }
        .overlay {
            if vm.isLoading, vm.fileDetail == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding()
            }
        }
    }

    private var fileSection: some View {
        Section(L10n.Viewer.Info.fileSection) {
            InfoRow(label: L10n.Viewer.Info.name, value: photo.name)
            InfoRow(label: L10n.Viewer.Info.type, value: photo.isVideo ? "Vidéo" : "Photo")
            InfoRow(label: L10n.Viewer.Info.size, value: InfoFormat.size(photo.size))
            if let exif = vm.exif, let w = exif.pixelWidth, let h = exif.pixelHeight {
                InfoRow(label: L10n.Viewer.Info.resolution, value: InfoFormat.resolution(width: w, height: h))
            }
        }
    }

    private var dateSection: some View {
        Section(L10n.Viewer.Info.dateSection) {
            InfoRow(label: L10n.Viewer.Info.takenAt, value: InfoFormat.date(photo.takenAt))
            InfoRow(label: L10n.Viewer.Info.addedAt, value: InfoFormat.date(photo.uploadedAt))
        }
    }

    private var videoSection: some View {
        Section(L10n.Viewer.Info.videoSection) {
            InfoRow(label: L10n.Viewer.Info.duration, value: InfoFormat.duration(photo.duration))
        }
    }

    @ViewBuilder
    private func cameraSection(_ exif: ExifMetadata) -> some View {
        Section(L10n.Viewer.Info.cameraSection) {
            if let make = exif.make, let model = exif.model {
                InfoRow(label: L10n.Viewer.Info.make, value: "\(make) \(model)")
            } else if let model = exif.model {
                InfoRow(label: L10n.Viewer.Info.make, value: model)
            }
            if let lens = exif.lens {
                InfoRow(label: L10n.Viewer.Info.lens, value: lens)
            }
            if let f = exif.fNumber {
                InfoRow(label: L10n.Viewer.Info.aperture, value: String(format: "f/%.1f", f))
            }
            if let t = exif.exposureTime {
                InfoRow(label: L10n.Viewer.Info.shutter, value: InfoFormat.shutter(t))
            }
            if let iso = exif.isoSpeed {
                InfoRow(label: L10n.Viewer.Info.iso, value: "\(iso)")
            }
            if let fl = exif.focalLength {
                InfoRow(label: L10n.Viewer.Info.focalLength, value: String(format: "%.0f mm", fl))
            }
        }
    }

    @ViewBuilder
    private func driveSection(_ detail: RemoteFileDetailDTO) -> some View {
        Section(L10n.Viewer.Info.kdriveSection) {
            if let path = detail.path {
                InfoRow(label: L10n.Viewer.Info.path, value: path)
            }
            if let hash = detail.hash {
                InfoRow(label: L10n.Viewer.Info.hash, value: String(hash.prefix(16)) + "…")
            }
        }
    }

    private func hasAnyCameraData(_ exif: ExifMetadata) -> Bool {
        exif.make != nil || exif.model != nil || exif.lens != nil
            || exif.fNumber != nil || exif.exposureTime != nil
            || exif.isoSpeed != nil || exif.focalLength != nil
    }
}

// MARK: - LocalPhotoInfoView

/// Fiche d'info simplifiée pour un média local-only (pas encore uploadé).
/// On affiche uniquement ce qui est lisible depuis PhotoKit sans tape sur l'API
/// kDrive : type, date, dimensions, durée (vidéo), localisation. Pas de section
/// "Fichier kDrive" ni de section "Appareil photo" (lecture EXIF du binaire
/// original = coût disque + permission, écarté volontairement pour rester léger).
private struct LocalPhotoInfoView: View {
    let asset: LocalAssetSnapshot
    @StateObject private var vm: LocalPhotoInfoViewModel

    init(asset: LocalAssetSnapshot) {
        self.asset = asset
        _vm = StateObject(wrappedValue: LocalPhotoInfoViewModel(asset: asset))
    }

    var body: some View {
        List {
            fileSection
            dateSection
            if asset.isVideo, let duration = vm.duration { videoSection(duration: duration) }
            if let loc = vm.location { LocationSection(location: loc) }
        }
        .task { await vm.load() }
    }

    private var fileSection: some View {
        Section(L10n.Viewer.Info.fileSection) {
            InfoRow(label: L10n.Viewer.Info.type, value: asset.isVideo ? "Vidéo" : "Photo")
            if let width = vm.pixelWidth, let height = vm.pixelHeight {
                InfoRow(
                    label: L10n.Viewer.Info.resolution,
                    value: InfoFormat.resolution(width: width, height: height)
                )
            }
        }
    }

    private var dateSection: some View {
        Section(L10n.Viewer.Info.dateSection) {
            InfoRow(label: L10n.Viewer.Info.takenAt, value: InfoFormat.date(asset.takenAt))
        }
    }

    private func videoSection(duration: Double) -> some View {
        Section(L10n.Viewer.Info.videoSection) {
            InfoRow(label: L10n.Viewer.Info.duration, value: InfoFormat.duration(duration))
        }
    }
}

// MARK: - LocalPhotoInfoViewModel

@MainActor
private final class LocalPhotoInfoViewModel: ObservableObject {
    @Published private(set) var pixelWidth: Int?
    @Published private(set) var pixelHeight: Int?
    @Published private(set) var duration: Double?
    @Published private(set) var location: PhotoLocation?

    private let asset: LocalAssetSnapshot

    init(asset: LocalAssetSnapshot) {
        self.asset = asset
    }

    func load() async {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
        guard let phAsset = fetch.firstObject else { return }

        pixelWidth = phAsset.pixelWidth
        pixelHeight = phAsset.pixelHeight
        if phAsset.mediaType == .video {
            duration = phAsset.duration
        }
        if let coord = phAsset.location?.coordinate {
            location = PhotoLocation(coordinate: coord, placeName: nil)
            let name = await Self.reverseGeocode(coord)
            if location?.coordinate.latitude == coord.latitude {
                location?.placeName = name
            }
        }
    }

    /// Même stratégie que `PhotoInfoViewModel.reverseGeocode` — toléré silencieusement
    /// si CLGeocoder rate-limit.
    private static func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        let parts = [placemark.name, placemark.locality, placemark.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}

// MARK: - ViewerActionsViewModel

@MainActor
private final class ViewerActionsViewModel: ObservableObject {
    @Published private(set) var albums: [AlbumSnapshot] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDownloading = false

    @InjectService private var api: PhotoApiFetching
    @InjectService private var photoWriter: PhotoWriting
    @InjectService private var albumManager: AlbumManaging
    @InjectService private var driveManager: DriveManaging
    @InjectService private var downloader: MediaDownloading
    @InjectService private var deletionQueueWriter: DeletionQueueWriting
    @InjectService private var deletionEngine: PhotoDeleting

    func loadAlbums() async {
        if let drive = try? driveManager.selectedDrive() {
            try? await albumManager.refreshAlbums(driveId: drive.id)
        }
        albums = (try? albumManager.allAlbums()) ?? []
    }

    func addToAlbum(photo: PhotoSnapshot, albumId: String) async {
        do {
            try await albumManager.addPhotos(fileIds: [photo.fileId], toAlbumId: albumId, driveId: photo.driveId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(photo: PhotoSnapshot) async -> Bool {
        // Enqueue persistant + drain immédiat. Si le drain réussit, le `Photo`
        // Realm est purgé dans la même transaction que le DeletionItem — la
        // galerie reflètera la suppression dès le prochain rebuild. On retourne
        // `true` dès que l'enqueue est fait : la fermeture du viewer ne dépend
        // pas du succès réseau (sinon on bloquerait le UX en cas de mauvaise
        // connexion, alors que la file persistera et finira par drainer).
        do {
            try await deletionQueueWriter.enqueueDeletion(
                fileId: photo.fileId,
                driveId: photo.driveId,
                localIdentifier: photo.localIdentifier
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        // Drain en best-effort. L'erreur éventuelle est capturée dans le
        // DeletionItem (state `.failedTransient/.failedPermanent`) — la
        // TimelineView lira les `lastDeletionFailures` à son prochain
        // `load()`/`refreshDeletionState`. On ne `await` pas ici pour que la
        // fermeture du viewer soit instantanée — `Task` hérite du main actor
        // mais `drain` est async et yieldera naturellement.
        Task {
            _ = await self.deletionEngine.drain { _ in }
        }
        return true
    }

    func download(photo: PhotoSnapshot) async -> Bool {
        guard !isDownloading else { return false }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let count = try await downloader.downloadAndImport(photos: [photo], driveId: photo.driveId)
            return count > 0
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - MediaPageView

private struct MediaPageView: View {
    /// Hauteurs des barres de la surcouche, mesurées depuis le bord de la safe
    /// area (padding + pilule). Servent à encadrer le lecteur vidéo natif pour
    /// que ses contrôles (AirPlay/son en haut, scrubber en bas) tombent dans la
    /// bande libre et ne chevauchent plus notre top/bottom bar.
    private static let appTopBarHeight: CGFloat = 48
    private static let appBottomBarHeight: CGFloat = 60
    private static let videoControlsGap: CGFloat = 16

    let media: ViewerMedia
    /// `true` quand cette page est la page courante du pager. Pilote la
    /// lecture vidéo : on démarre à l'ouverture de la page et on met en pause
    /// dès qu'on swipe vers un autre média (évite l'audio d'une vidéo hors-écran).
    let isActive: Bool
    /// Safe area de l'écran, propagée depuis le `GeometryReader` racine (le
    /// pager l'ignore, elle n'est donc pas lisible localement).
    let safeArea: EdgeInsets
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void

    @StateObject private var loader: MediaPageLoader

    init(
        media: ViewerMedia,
        isActive: Bool,
        safeArea: EdgeInsets,
        onSingleTap: @escaping () -> Void,
        onZoomChange: @escaping (Bool) -> Void
    ) {
        self.media = media
        self.isActive = isActive
        self.safeArea = safeArea
        self.onSingleTap = onSingleTap
        self.onZoomChange = onZoomChange
        _loader = StateObject(wrappedValue: MediaPageLoader(media: media))
    }

    var body: some View {
        ZStack {
            Color.black

            if let image = loader.image {
                ZoomableScrollView(
                    image: image,
                    onSingleTap: onSingleTap,
                    onZoomChange: onZoomChange
                )
            } else if let player = loader.player {
                // Le lecteur natif est encadré dans la bande située entre les
                // deux barres de la surcouche : ses contrôles (AirPlay/son en
                // haut, scrubber en bas) suivent les bords de ce cadre et ne
                // chevauchent donc plus notre top/bottom bar.
                // Pas de `.onTapGesture` : on laisse le lecteur natif capter les
                // taps pour afficher/masquer ses propres contrôles.
                VideoPlayer(player: player)
                    .padding(.top, safeArea.top + Self.appTopBarHeight + Self.videoControlsGap)
                    .padding(.bottom, safeArea.bottom + Self.appBottomBarHeight + Self.videoControlsGap)
                    .onAppear { if isActive { player.play() } }
                    .onChange(of: isActive) { active in
                        if active { player.play() } else { player.pause() }
                    }
            } else if loader.isLoadingPreview {
                ProgressView().tint(.white)
            } else if let error = loader.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button(L10n.Common.retry) {
                        Task { await loader.load() }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .task { await loader.load() }
    }
}

// MARK: - MediaPageLoader

/// Chargement en deux phases :
/// 1. Au `init`, on remplit `image` immédiatement avec la vignette déjà en cache
///    (issue du défilement de la galerie) — évite tout flash de loader.
/// 2. Au `load()`, on délègue à la stratégie correspondant à la source :
///    - `.cloud` : preview HD kDrive (cache disque, puis API width=2500/height=1500/quality=80).
///    - `.local` : `PHImageManager` (taille max, accès iCloud Photo Library autorisé).
///
/// Chaque branche reste autonome ; la classe sert d'aiguillage et factorise l'état
/// publié (`image`, `player`, `isLoadingPreview`, `errorMessage`).
@MainActor
private final class MediaPageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var errorMessage: String?

    private let media: ViewerMedia
    private var didLoadPreview = false

    @InjectService private var api: PhotoApiFetching
    @InjectService private var auth: AuthService

    /// Dimensions ciblées pour le preview HD. Cf. valeurs utilisées par l'app
    /// officielle iOS kDrive — bon compromis qualité / poids réseau.
    private let previewWidth = 2500
    private let previewHeight = 1500
    private let previewQuality = 80

    init(media: ViewerMedia) {
        self.media = media
        prefillFromCache()
    }

    func load() async {
        switch media {
        case .cloud(let snapshot):
            await loadCloud(snapshot)
        case .local(let asset):
            await loadLocal(asset)
        }
    }

    // MARK: Pré-remplissage

    /// Pré-remplissage cloud uniquement : pour le local, la vignette PhotoKit est
    /// gérée par `LocalThumbnailLoader` (cache `PHCachingImageManager`) et n'est
    /// pas accessible via une simple lookup synchrone — on accepte un bref
    /// `ProgressView` au premier ouvrage.
    private func prefillFromCache() {
        guard case .cloud(let photo) = media, !photo.isVideo else { return }
        let key = ThumbnailLoader.cacheKey(driveId: photo.driveId, fileId: photo.fileId, revision: photo.remoteRevision)
        if let cached = ThumbnailCache.shared.image(forKey: key)
            ?? ThumbnailCache.shared.diskImage(forKey: key) {
            image = cached
        }
        if let highRes = PreviewCache.shared.image(forKey: key) {
            image = highRes
            didLoadPreview = true
        }
    }

    // MARK: Cloud

    private func loadCloud(_ photo: PhotoSnapshot) async {
        if photo.isVideo {
            if player != nil { return }
            do {
                let token = try await auth.currentAccessToken()
                let url = api.downloadURL(driveId: photo.driveId, fileId: photo.fileId)
                let headers = ["Authorization": "Bearer \(token)"]
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        if didLoadPreview { return }
        let key = ThumbnailLoader.cacheKey(driveId: photo.driveId, fileId: photo.fileId, revision: photo.remoteRevision)

        if let disk = PreviewCache.shared.diskImage(forKey: key) {
            PreviewCache.shared.store(disk, forKey: key)
            image = disk
            didLoadPreview = true
            return
        }

        isLoadingPreview = true
        defer { isLoadingPreview = false }
        do {
            let data = try await api.previewData(
                driveId: photo.driveId,
                fileId: photo.fileId,
                width: previewWidth,
                height: previewHeight,
                quality: previewQuality
            )
            if let highRes = UIImage(data: data) {
                PreviewCache.shared.store(highRes, forKey: key)
                PreviewCache.shared.storeOnDisk(data, forKey: key)
                image = highRes
                didLoadPreview = true
            }
            errorMessage = nil
        } catch {
            // Si on a déjà une vignette en placeholder, on ne masque pas avec un message d'erreur.
            if image == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Local (PhotoKit)

    private func loadLocal(_ asset: LocalAssetSnapshot) async {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
        guard let phAsset = fetch.firstObject else {
            // Asset disparu de la photothèque entre l'index et l'ouverture du viewer.
            if image == nil { errorMessage = L10n.Common.errorGeneric }
            return
        }

        if asset.isVideo {
            if player != nil { return }
            if let item = await Self.requestPlayerItem(for: phAsset) {
                player = AVPlayer(playerItem: item)
                errorMessage = nil
            } else if player == nil {
                errorMessage = L10n.Common.errorGeneric
            }
            return
        }

        if didLoadPreview { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        if let result = await Self.requestImage(for: phAsset) {
            image = result
            didLoadPreview = true
            errorMessage = nil
        } else if image == nil {
            errorMessage = L10n.Common.errorGeneric
        }
    }

    /// Récupère une image plein-cadre depuis PhotoKit. `PHImageManagerMaximumSize`
    /// renvoie l'asset à sa taille native — le `ZoomableScrollView` se chargera
    /// du fit à l'écran. `isNetworkAccessAllowed = true` couvre les assets stockés
    /// dans iCloud Photo Library (photo qui n'a pas encore retéléchargé localement).
    private nonisolated static func requestImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .none
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !didResume, !degraded else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    private nonisolated static func requestPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            var didResume = false
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: item)
            }
        }
    }
}

// MARK: - ZoomableScrollView

/// UIScrollView wrappé en UIViewRepresentable pour le zoom pinch natif.
/// Quand zoomScale == 1, le pan interne ne défile pas (le contenu tient dans
/// le cadre) : le geste de pagination/dismiss du parent reste donc seul maître.
/// Quand zoomScale > 1, le pan de l'UIScrollView prend la priorité.
///
/// `onZoomChange` est appelé à chaque variation du zoom (utilisé par le parent
/// pour désactiver le geste swipe-to-dismiss tant que la photo est zoomée).
private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChange: onZoomChange)
    }

    func makeUIView(context: Context) -> ScrollContainer {
        let container = ScrollContainer()
        container.configure(image: image, coordinator: context.coordinator)
        context.coordinator.container = container
        return container
    }

    func updateUIView(_ container: ScrollContainer, context: Context) {
        if container.imageView.image !== image {
            container.imageView.image = image
            container.scrollView.zoomScale = 1
            container.setNeedsLayout()
            // Reset zoom callback : nouvelle image → toujours dézoomée.
            context.coordinator.onZoomChange(false)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let onSingleTap: () -> Void
        let onZoomChange: (Bool) -> Void
        weak var container: ScrollContainer?

        init(onSingleTap: @escaping () -> Void, onZoomChange: @escaping (Bool) -> Void) {
            self.onSingleTap = onSingleTap
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            container?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            container?.centerImageView()
            // Tolérance pour le bouncing : on considère zoomé dès > 1.01.
            onZoomChange(scrollView.zoomScale > 1.01)
        }

        @objc
        func handleSingleTap() {
            onSingleTap()
        }

        @objc
        func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = container?.scrollView,
                  let imageView = container?.imageView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let location = gesture.location(in: imageView)
                let zoomRect = CGRect(
                    x: location.x - imageView.bounds.width / 4,
                    y: location.y - imageView.bounds.height / 4,
                    width: imageView.bounds.width / 2,
                    height: imageView.bounds.height / 2
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}

// MARK: - ScrollContainer

/// UIView wrapper qui contient le UIScrollView pour gérer le layout
/// proprement via `layoutSubviews` (les bounds sont garantis corrects).
private final class ScrollContainer: UIView {
    let scrollView = UIScrollView()
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(image: UIImage, coordinator: ZoomableScrollView.Coordinator) {
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(ZoomableScrollView.Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(ZoomableScrollView.Coordinator.handleSingleTap)
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        layoutImageView()
    }

    func layoutImageView() {
        guard let image = imageView.image else { return }
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }

        let imageRatio = image.size.width / image.size.height
        let boundsRatio = boundsSize.width / boundsSize.height

        let fitSize: CGSize
        if imageRatio > boundsRatio {
            fitSize = CGSize(width: boundsSize.width, height: boundsSize.width / imageRatio)
        } else {
            fitSize = CGSize(width: boundsSize.height * imageRatio, height: boundsSize.height)
        }

        imageView.frame = CGRect(origin: .zero, size: fitSize)
        scrollView.contentSize = fitSize
        centerImageView()
    }

    func centerImageView() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let offsetX = max((boundsSize.width - contentSize.width) / 2, 0)
        let offsetY = max((boundsSize.height - contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: offsetY, left: offsetX, bottom: offsetY, right: offsetX
        )
    }
}

// MARK: - Glass Pill Helper

private extension View {
    /// Pilule glass hybride : sur iOS 26+ on bénéficie du nouveau matériau Liquid
    /// Glass (avec reflets et distorsions), sur iOS 16-25 on retombe sur
    /// `ultraThinMaterial` + liseré fin pour mimer l'effet. Le compilateur ne
    /// connaît `glassEffect` que si on build avec le SDK iOS 26+ ; on garde donc
    /// la branche en `#if compiler(>=6.2)` (Swift 6.2 = Xcode 26 = SDK iOS 26).
    @ViewBuilder
    func glassPill(in shape: some InsettableShape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        #else
        background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        #endif
    }
}
