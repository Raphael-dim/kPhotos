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

struct SectionAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

// Frames absolus des tiles dans l'espace global. Sert au drag-to-select pour
// hit-tester l'item sous le doigt sans avoir à descendre dans la hiérarchie.
struct TileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// Frame global du ScrollView — utilisé pour déterminer les zones d'auto-scroll
// (haut/bas) pendant le drag-select.
struct ScrollFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

enum AutoScrollDirection { case up, down }

/// Wrapper Identifiable pour pouvoir passer l'état du viewer à `.fullScreenCover(item:)`.
struct TimelineViewerPresentation: Identifiable {
    let id = UUID()
    let media: [ViewerMedia]
    let index: Int
    let galleryItemIDs: [String: String]
}

/// Notification in-app affichée brièvement (toast) à la fin d'une synchronisation.
struct SyncToast: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let message: String
    /// Détail d'erreur — non nil quand `kind == .error`, ouvert au tap du toast.
    let errorDetail: String?

    enum Kind { case success, error }
    static func forSyncState(_ state: TimelineViewModel.SyncState) -> SyncToast? {
        switch state {
        case .finished(let progress):
            .init(kind: .success, message: L10n.Timeline.syncDone(uploaded: progress.completed), errorDetail: nil)
        case .failed(let message):
            .init(kind: .error, message: L10n.Common.errorGeneric, errorDetail: message)
        case .idle, .running:
            nil
        }
    }
}

/// Données affichées par la sheet de détail d'échec **par photo**. Distincte de
/// `detailedError: String?` (sheet d'erreur globale de session sync) — celle-ci
/// porte le `localIdentifier` pour permettre les actions "Réessayer" / "Ignorer".
struct ItemFailureSheet: Identifiable {
    let id = UUID()
    let localIdentifier: String
    let reason: String
}

/// Sheet d'échec de suppression par photo — distinct de l'upload car les
/// actions diffèrent (retry suppression vs annuler suppression, pas de skip).
struct DeletionFailureSheet: Identifiable {
    let id = UUID()
    let fileId: String
    let reason: String
}

struct SyncToastView: View {
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
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.kind {
        case .success: .green
        case .error: .orange
        }
    }
}

// MARK: - GalleryTile

/// Internal (= module-scope) pour pouvoir être réutilisé dans `AlbumDetailView`
/// sans dupliquer le rendu. Hors timeline, les états `pendingUpload/uploading`
/// ne s'appliquent pas — passer `syncState = .synced` (ou `.cloudOnly`) côté
/// caller dans ce cas.
