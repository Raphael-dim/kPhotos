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
import SwiftUI
import UIKit

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
            true
        default:
            false
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: size, height: size)

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
        .mediaViewerSource(id: item.viewerTransitionID, in: namespace)
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

    @ViewBuilder private var thumbnail: some View {
        if let localId = item.localAssetIdentifier {
            LocalThumbnail(localIdentifier: localId, size: size)
        } else if let driveId = item.cloudDriveId, let fileId = item.cloudFileId {
            CloudThumbnail(driveId: driveId, fileId: fileId, size: size, pack: item.thumbnailPack, revision: item.remoteRevision)
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

private struct CloudThumbnailPriorityKey: EnvironmentKey {
    static let defaultValue = 2
}

private struct LoadsCloudThumbnailKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var cloudThumbnailPriority: Int {
        get { self[CloudThumbnailPriorityKey.self] }
        set { self[CloudThumbnailPriorityKey.self] = newValue }
    }

    var loadsCloudThumbnail: Bool {
        get { self[LoadsCloudThumbnailKey.self] }
        set { self[LoadsCloudThumbnailKey.self] = newValue }
    }
}

struct CloudThumbnail: View {
    @Environment(\.loadsCloudThumbnail) private var shouldLoad
    @Environment(\.cloudThumbnailPriority) private var priority
    let driveId: Int
    let fileId: String
    let size: CGFloat
    let pack: ThumbnailPackReference?
    let revision: String
    @StateObject private var loader: ThumbnailLoader

    init(driveId: Int, fileId: String, size: CGFloat, pack: ThumbnailPackReference? = nil, revision: String = "") {
        self.driveId = driveId
        self.fileId = fileId
        self.size = size
        self.pack = pack; self.revision = revision
        _loader = StateObject(wrappedValue: ThumbnailLoader(driveId: driveId, fileId: fileId, pack: pack, revision: revision))
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
        .task(id: "\(shouldLoad)-\(priority)-\(revision)-\(pack?.sha256 ?? "")") {
            loader.configure(pack: pack, revision: revision)
            if shouldLoad { await loader.load(priority: priority) } else { loader.releaseImage() }
        }
        .onDisappear { loader.releaseImage() }
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
