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

import CoreLocation
import kPhotosCore
import kPhotosResources
import MapKit
import SwiftUI

struct MapSelectedPhotos: Identifiable {
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

struct MapViewerPresentation: Identifiable {
    let id = UUID()
    let photos: [PhotoSnapshot]
    let index: Int
}

// MARK: - Place row

/// Ligne d'un lieu dans la liste : miniature de la photo la plus récente +
/// nom du lieu (résolu via CLGeocoder, fallback sur coords) + nombre de photos.
struct PlaceRow: View {
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
struct PlaceThumbnail: View {
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

struct PlaceThumbnailImage: View {
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
struct FullMapScreen: View {
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
struct PhotoLocationSheet: View {
    let photos: [PhotoSnapshot]
    /// Titre d'amorce (adresse cluster, ou coords) affiché immédiatement.
    let initialTitle: String
    /// Coord précise du tap : si fournie, le sheet déclenche un reverse-geocode
    /// fin (rue + quartier) et remplace `initialTitle` une fois résolu.
    let preciseCoordinate: CLLocationCoordinate2D?
    @State private var viewerPresentation: MapViewerPresentation?
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
                                viewerPresentation = MapViewerPresentation(photos: photos, index: index)
                            } label: {
                                MapSheetThumbnail(photo: photo)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                            .mediaViewerSource(id: ViewerMedia.cloud(photo).id, in: viewerNamespace)
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
                onCurrentMediaChange: { mediaID in
                    currentFileID = presentation.photos.first { ViewerMedia.cloud($0).id == mediaID }?.fileId
                },
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
struct MapSheetThumbnail: View {
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
