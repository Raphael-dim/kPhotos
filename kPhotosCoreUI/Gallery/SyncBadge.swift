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

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import kPhotosCore
import SwiftUI

/// Pastille de statut de synchro affichée en bas-droite des tuiles de la galerie.
/// Discret : 14pt, opacité ultraThinMaterial. N'affiche rien en état `synced` ni
/// `cloudOnly` (cas nominaux).
///
/// Quand `state == .uploadFailed` ET que `onFailureTap` est fourni, le badge devient
/// tappable — utilisé par la timeline pour ouvrir la sheet "Détail de l'erreur" sans
/// ouvrir le viewer plein écran (le tap est consommé par le badge, pas par la tuile).
public struct SyncBadge: View {
    private let state: GalleryItemSyncState
    private let onFailureTap: (() -> Void)?

    public init(state: GalleryItemSyncState, onFailureTap: (() -> Void)? = nil) {
        self.state = state
        self.onFailureTap = onFailureTap
    }

    public var body: some View {
        switch state {
        case .localOnly:
            badge(systemName: "icloud.slash", tint: .secondary)
        case .pendingUpload:
            badge(systemName: "icloud.and.arrow.up", tint: .accentColor)
        case .uploading(let fraction):
            uploadingBadge(fraction: fraction)
        case .uploadFailed(let reason):
            failureBadge(reason: reason)
        case .synced, .cloudOnly:
            EmptyView()
        case .deletionPending:
            // Badge "en attente de suppression" — trash + halo discret. La tile
            // sera grisée côté GalleryTile (cf. `dimmedForDeletion`).
            badge(systemName: "trash", tint: .secondary)
        case .deleting:
            // Spinner sur fond trash : la requête est en vol côté kDrive.
            deletingBadge()
        case .deletionFailed(let reason):
            deletionFailureBadge(reason: reason)
        }
    }

    private func failureBadge(reason: String) -> some View {
        tappableErrorBadge(systemName: "exclamationmark.icloud", tint: .orange, reason: reason)
    }

    private func badge(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(5)
            .background(.ultraThinMaterial, in: Circle())
            .padding(6)
    }

    /// Badge "suppression en cours" : poubelle + petit spinner overlay. Le DELETE
    /// kDrive est rapide donc on n'a pas de fraction — toujours indéterminé.
    private func deletingBadge() -> some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: 22, height: 22)
            ProgressView()
                .controlSize(.mini)
                .tint(.red)
        }
        .padding(6)
    }

    private func deletionFailureBadge(reason: String) -> some View {
        tappableErrorBadge(systemName: "exclamationmark.triangle.fill", tint: .red, reason: reason)
    }

    /// Tappable uniquement quand on a une vraie cause ET un handler — évite une
    /// tap-zone qui ouvrirait une sheet vide. Hit-zone restreinte au cercle.
    @ViewBuilder
    private func tappableErrorBadge(systemName: String, tint: Color, reason: String) -> some View {
        let icon = badge(systemName: systemName, tint: tint)
        if let onFailureTap, !reason.isEmpty {
            Button(action: onFailureTap) { icon }
                .buttonStyle(.plain)
                .contentShape(Circle())
        } else {
            icon
        }
    }

    /// Spinner circulaire — `fraction` connu = anneau de progression, sinon spinner
    /// indéterminé. (Aujourd'hui l'upload non-chunked ne remonte pas la fraction.)
    private func uploadingBadge(fraction: Double?) -> some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: 22, height: 22)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 16, height: 16)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.accentColor)
            }
        }
        .padding(6)
    }
}
