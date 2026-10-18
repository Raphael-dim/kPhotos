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
import MapKit
import SwiftUI

/// Page Carte : la vue par défaut est désormais une liste "Lieux" inspirée d'iOS
/// Photos — minimap cliquable au sommet, suivie d'une liste de lieux (clusters
/// géographiques) avec miniature + nom + nombre de photos. Le tap sur la minimap
/// pousse la carte interactive (clusters MapKit) sur la `NavigationStack`.
public struct PhotoMapView: View {
    @StateObject private var viewModel = PhotoMapViewModel()
    @State private var selectedPhotos: SelectedPhotos?
    @State private var showPreparation = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.metadataProgress.total > 0 || viewModel.metadataProgress.isRunning
                        || viewModel.metadataProgress.isPaused {
                        preparationStatus
                            .padding(.horizontal, 16)
                    }
                    content
                }
                .padding(.vertical, 16)
            }
            .toolbar {
                ToolbarItem(placement: .appPrimaryAction) {
                    Button { showPreparation = true } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel(L10n.Common.more)
                }
            }
            .navigationTitle(L10n.Map.title)
            .navigationBarTitleDisplayMode(.large)
            .task { await viewModel.load() }
            .sheet(isPresented: $showPreparation) { PlacePreparationSheet(viewModel: viewModel) }
            .sheet(item: $selectedPhotos) { selection in
                PhotoLocationSheet(
                    photos: selection.photos,
                    initialTitle: selection.title,
                    preciseCoordinate: selection.preciseCoordinate
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var preparationStatus: some View {
        let status = PlacePreparationStatus(progress: viewModel.metadataProgress)
        return LibraryStatusButton(
            title: status.title,
            subtitle: status.subtitle,
            symbol: status.symbol,
            tone: status.tone,
            progress: status.phase == .running ? status.fraction : nil,
            action: { showPreparation = true }
        )
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .loading:
            loadingState
        case .permissionNeeded:
            permissionState(denied: false)
        case .permissionDenied:
            permissionState(denied: true)
        case .empty:
            emptyState
        case .error(let message):
            errorState(message: message)
        case .ready(let points):
            readyMap(points: points)
        }
    }

    // MARK: Ready state

    /// Vue par défaut : minimap cliquable en haut, liste des lieux en dessous.
    /// Le tap sur la minimap pousse la carte plein écran avec clusters MapKit.
    /// Le tap sur un lieu pousse la grille de photos correspondante.
    private func readyMap(points: [PhotoMapPoint]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink {
                FullMapScreen(points: points) { tapped in
                    let center = Self.centerCoordinate(for: tapped, in: points)
                    selectedPhotos = SelectedPhotos(
                        photos: tapped,
                        title: viewModel.placeName(forAny: tapped)
                            ?? Self.formatFallback(center),
                        preciseCoordinate: center
                    )
                }
            } label: {
                miniMapPreview(points: points)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    )
                    // `Map` interne a `.allowsHitTesting(false)`, donc sans
                    // `contentShape` SwiftUI considère le label comme vide
                    // côté hit-test et le NavigationLink ne fire jamais.
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            Text(L10n.Map.placesSectionTitle)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 4)

            ForEach(viewModel.placeGroups) { group in
                Button {
                    selectedPhotos = SelectedPhotos(
                        photos: group.photos,
                        title: group.placeName
                            ?? String(
                                format: "%.2f, %.2f",
                                group.centerLatitude,
                                group.centerLongitude
                            ),
                        // Pas de geocoding fin : à l'échelle d'un cluster
                        // 50km, le centre n'est pas représentatif d'une rue.
                        preciseCoordinate: nil
                    )
                } label: {
                    PlaceRow(group: group)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 24)
    }

    /// Minimap statique non-interactive : aperçu cliquable de toutes les photos
    /// géolocalisées. La région inclut tous les points pour donner une vue
    /// d'ensemble. Pas de clusters MapKit ici — c'est purement décoratif.
    @ViewBuilder
    private func miniMapPreview(points: [PhotoMapPoint]) -> some View {
        let region = Self.boundingRegion(for: points)
        let overview = stride(from: 0, to: points.count, by: max(1, (points.count + 255) / 256)).map { points[$0] }
        if #available(iOS 17.0, *) {
            Map(position: .constant(.region(region)), interactionModes: []) {
                ForEach(overview) { point in
                    Annotation(
                        point.photo.takenAt.formatted(date: .abbreviated, time: .omitted),
                        coordinate: CLLocationCoordinate2D(
                            latitude: point.latitude,
                            longitude: point.longitude
                        )
                    ) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
        } else {
            Map(coordinateRegion: .constant(region), interactionModes: [], annotationItems: overview) { point in
                MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Coordonnée moyenne des points correspondant aux photos tappées.
    /// Sert à la fois au titre de fallback et au reverse-geocoding fin du sheet.
    fileprivate static func centerCoordinate(
        for photos: [PhotoSnapshot],
        in points: [PhotoMapPoint]
    ) -> CLLocationCoordinate2D? {
        let ids = Set(photos.map(\.fileId))
        let matching = points.filter { ids.contains($0.photo.fileId) }
        guard !matching.isEmpty else { return nil }
        let lat = matching.map(\.latitude).reduce(0, +) / Double(matching.count)
        let lon = matching.map(\.longitude).reduce(0, +) / Double(matching.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Fallback texte affiché tant que le reverse-geocoding n'a pas répondu.
    fileprivate static func formatFallback(_ coord: CLLocationCoordinate2D?) -> String {
        guard let coord else { return "" }
        return String(format: "%.2f, %.2f", coord.latitude, coord.longitude)
    }

    /// Bounding box englobant tous les points + un petit padding (10% de marge).
    private static func boundingRegion(for points: [PhotoMapPoint]) -> MKCoordinateRegion {
        guard !points.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 46.5, longitude: 6.6),
                span: MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20)
            )
        }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.5, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.5, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: Other states

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(L10n.Map.loading)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        EmptyStateView(systemImage: "mappin.slash", title: L10n.Map.emptyTitle, subtitle: L10n.Map.emptySubtitle)
    }

    private func permissionState(denied: Bool) -> some View {
        EmptyStateView(
            systemImage: "photo.on.rectangle.angled",
            title: L10n.Map.permissionTitle,
            subtitle: denied ? L10n.Map.permissionDeniedSubtitle : L10n.Map.permissionSubtitle,
            actionTitle: denied ? L10n.Map.openSettings : L10n.Map.allowAccess,
            action: {
                if denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } else {
                    Task { await viewModel.requestPhotoLibraryAccess() }
                }
            }
        )
    }

    private func errorState(message: String) -> some View {
        ErrorStateView(title: L10n.Common.errorGeneric, message: message, retryTitle: L10n.Common.retry) {
            Task { await viewModel.load() }
        }
    }
}

// MARK: - Bottom sheet support

private struct SelectedPhotos: Identifiable {
    let id = UUID()
    let photos: [PhotoSnapshot]
    /// Titre déjà résolu côté appelant (adresse cluster via CLGeocoder, ou
    /// fallback coords si pas encore résolu). Sert d'affichage initial.
    let title: String
    /// Coordonnée précise à reverse-geocoder pour obtenir une adresse fine
    /// (rue + quartier). Nil = pas de geocoding fin (cas du tap sur une ligne
    /// de la liste : on garde le `placeName` de cluster, le centre cluster est
    /// peu pertinent à la rue près).
    let preciseCoordinate: CLLocationCoordinate2D?
}

private struct ViewerPresentation: Identifiable {
    let id = UUID()
    let photos: [PhotoSnapshot]
    let index: Int
}

// MARK: - Place row

/// Ligne d'un lieu dans la liste : miniature de la photo la plus récente +
/// nom du lieu (résolu via CLGeocoder, fallback sur coords) + nombre de photos.
private struct PlaceRow: View {
    let group: PlaceGroup

    var body: some View {
        HStack(spacing: 14) {
            PlaceThumbnail(photo: group.photos.first)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(group.placeName ?? fallbackName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(L10n.Map.placeItemsCount(count: group.photoCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Affichage par défaut tant que le reverse géocoding n'a pas répondu :
    /// coordonnées arrondies. Évite un état vide qui ferait sauter la ligne.
    private var fallbackName: String {
        String(format: "%.2f, %.2f", group.centerLatitude, group.centerLongitude)
    }
}

/// Miniature de la première photo d'un lieu. Délègue à `ThumbnailLoader`
/// (RAM → disque → API) pour que les vignettes apparaissent même si la galerie
/// n'a pas encore peuplé le cache au préalable.
private struct PlaceThumbnail: View {
    let photo: PhotoSnapshot?

    var body: some View {
        ZStack {
            Color(.systemGray5)
            if let photo {
                PlaceThumbnailImage(photo: photo)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaceThumbnailImage: View {
    let photo: PhotoSnapshot
    @StateObject private var loader: ThumbnailLoader

    init(photo: PhotoSnapshot) {
        self.photo = photo
        _loader = StateObject(wrappedValue: ThumbnailLoader(
            driveId: photo.driveId,
            fileId: photo.fileId,
            pack: photo.thumbnailPack,
            revision: photo.remoteRevision
        ))
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: photo.remoteRevision + (photo.thumbnailPack?.sha256 ?? "")) {
            loader.configure(pack: photo.thumbnailPack, revision: photo.remoteRevision)
            await loader.load()
        }
    }
}

// MARK: - Full map screen

/// Carte plein écran avec clusters MapKit — poussée sur la `NavigationStack`
/// quand l'utilisateur tape sur la minimap. Pas de modal : navigation native iOS
/// (bouton back automatique). Reprend `PhotoMapKitView` (clustering natif déjà
/// câblé) et propage le tap d'annotation pour ouvrir la grille de photos.
private struct FullMapScreen: View {
    let points: [PhotoMapPoint]
    let onAnnotationTap: ([PhotoSnapshot]) -> Void

    var body: some View {
        PhotoMapKitView(points: points) { photos in
            onAnnotationTap(photos)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(L10n.Map.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Bottom sheet listant les photos d'une annotation tappée (single ou cluster).
/// Grille fluide, tap sur une vignette → ouvre le viewer plein écran.
private struct PhotoLocationSheet: View {
    let photos: [PhotoSnapshot]
    /// Titre d'amorce (adresse cluster, ou coords) affiché immédiatement.
    let initialTitle: String
    /// Coord précise du tap : si fournie, le sheet déclenche un reverse-geocode
    /// fin (rue + quartier) et remplace `initialTitle` une fois résolu.
    let preciseCoordinate: CLLocationCoordinate2D?
    @State private var viewerPresentation: ViewerPresentation?
    @State private var currentFileID: String?
    @Namespace private var viewerNamespace
    @State private var resolvedTitle: String?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.element.fileId) { index, photo in
                            Button {
                                currentFileID = nil
                                viewerPresentation = ViewerPresentation(photos: photos, index: index)
                            } label: {
                                MapSheetThumbnail(photo: photo)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 16)
                }
                .onChange(of: currentFileID) { fileID in
                    guard let fileID else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollProxy.scrollTo(fileID, anchor: .center) }
                }
            }
            .navigationTitle(resolvedTitle ?? initialTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: preciseCoordinate.map { "\($0.latitude),\($0.longitude)" } ?? "") {
                await resolvePreciseAddress()
            }
        }
        .fullScreenCover(item: $viewerPresentation) { presentation in
            FullscreenMediaView(
                media: presentation.photos.map(ViewerMedia.cloud),
                initialIndex: presentation.index,
                namespace: viewerNamespace,
                onClose: { viewerPresentation = nil }
            )
        }
    }

    /// Reverse-geocode le point exact du tap pour obtenir une adresse à la rue.
    /// On garde l'ancien titre tant que CLGeocoder n'a pas répondu (et on tombe
    /// dessus en cas d'échec — pas la peine d'écraser un fallback "Paris" déjà
    /// décent par une erreur).
    private func resolvePreciseAddress() async {
        guard let coord = preciseCoordinate else { return }
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first,
               let address = PhotoMapViewModel.formatPreciseAddress(placemark) {
                resolvedTitle = address
            }
        } catch {
            // Échec silencieux — on garde initialTitle.
        }
    }
}

/// Vignette d'une photo cloud dans le bottom sheet de la carte. Délègue à
/// `ThumbnailLoader` (RAM → disque → API) pour que les vignettes s'affichent
/// même quand la galerie n'a pas encore peuplé le cache.
private struct MapSheetThumbnail: View {
    let photo: PhotoSnapshot
    @StateObject private var loader: ThumbnailLoader

    init(photo: PhotoSnapshot) {
        self.photo = photo
        _loader = StateObject(wrappedValue: ThumbnailLoader(
            driveId: photo.driveId,
            fileId: photo.fileId,
            pack: photo.thumbnailPack,
            revision: photo.remoteRevision
        ))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemGray5)
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                if photo.isVideo {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.5), in: Circle())
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: photo.remoteRevision + (photo.thumbnailPack?.sha256 ?? "")) {
                loader.configure(pack: photo.thumbnailPack, revision: photo.remoteRevision)
                await loader.load()
            }
        }
    }
}
