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

import SwiftUI
import UIKit

@MainActor
final class TimelineGridInteraction: ObservableObject {
    let viewModel: TimelineViewModel
    /// Index du niveau de densité courant dans `Self.zoomLevels`. La grille a un
    /// nombre de colonnes discret ; le pinch fait basculer d'un cran à l'autre.
    @Published var zoomLevelIndex = TimelineGridInteraction.defaultZoomLevelIndex
    /// Échelle homothétique appliquée en direct à la grille pendant le pinch
    /// (`.scaleEffect`). 1.0 = état stable. Animée vers 1.0 à la fin du geste —
    /// soit en se figeant sur le nouveau niveau, soit en ressort inverse.
    @Published var gestureScale: CGFloat = 1.0
    /// Épicentre du pinch — point médian des deux doigts, exprimé en `UnitPoint`
    /// du conteneur. Sert d'ancrage au `.scaleEffect` : le contenu sous ce point
    /// reste rigoureusement fixe pendant tout le geste.
    @Published var gestureAnchor: UnitPoint = .center
    /// `true` entre le début et la fin d'un pinch valide. Garde anti-rebond pour
    /// `onChanged`/`onEnded` quand le geste a été ignoré au départ (drag-select actif).
    @Published var isPinching = false
    /// Tile sous l'épicentre au début du pinch — cible du recentrage du scroll
    /// après un changement de niveau, pour que la zone visée reste à l'écran.
    @Published var pinchAnchorTileId: String?
    /// Position verticale de l'épicentre dans le viewport au début du pinch
    /// (0 = haut, 1 = bas). Réutilisée comme ancre du `scrollTo` post-snap.
    @Published var pinchAnchorViewportFraction: CGFloat = 0.5
    /// `true` quand l'échelle courante a franchi le seuil de bascule — pilote le
    /// petit retour haptique « cran prêt » et évite de le rejouer en continu.
    @Published var pinchArmedForCommit = false
    /// Frames absolus de toutes les tiles visibles, capturées via PreferenceKey.
    /// Sert au hit-testing du drag-to-select sans descendre dans la hiérarchie.
    @Published var tileFrames: [String: CGRect] = [:]
    /// Frame absolu du ScrollView, utilisé pour décider quand auto-scroller
    /// (zone tampon = 10% des bords haut/bas) et pour la vitesse proportionnelle.
    @Published var scrollViewGlobalFrame: CGRect = .zero
    /// Item d'ancrage du drag-to-select — set quand le long-press confirme,
    /// nil quand le geste se termine. Sert aussi de garde multi-touch : tout
    /// long-press secondaire pendant qu'un anchor est déjà actif est ignoré.
    @Published var dragSelectAnchorId: String?
    /// Snapshot de la sélection au moment où le long-press fire. La règle de
    /// composition pendant le drag est `selection = snapshot ∪ range_courante`,
    /// ce qui donne automatiquement la désélection en marche arrière (les items
    /// quittant la range disparaissent de la sélection s'ils n'étaient pas
    /// initialement sélectionnés).
    @Published var dragSelectInitialSelection: Set<String> = []
    /// Dernière position globale du doigt — réutilisée par l'auto-scroll quand
    /// la grille défile sans que le doigt bouge (le hit-test doit alors être
    /// recalculé avec les nouvelles positions des tiles).
    @Published var lastDragLocation: CGPoint?
    /// Timer d'auto-scroll pendant le drag-select (zone tampon haut/bas).
    @Published var autoScrollTimer: Timer?
    /// Intensité de l'auto-scroll en [0, 1] — 0 = entrée dans la zone, 1 = bord
    /// absolu. Recalculée à chaque mouvement du doigt.
    @Published var autoScrollIntensity: CGFloat = 0
    @Published var autoScrollDirection: AutoScrollDirection = .down
    /// Accumulateur de rows fractionnaires — permet d'avancer de "0.3 row" par
    /// tick à faible intensité sans perdre la fraction d'un tick à l'autre.
    @Published var autoScrollRowAccumulator: CGFloat = 0
    /// Référence au `UIScrollView` sous-jacent à la SwiftUI `ScrollView`, captée
    /// par introspection (`ScrollViewIntrospector` placé dans le contenu). On
    /// l'utilise pour piloter l'auto-scroll en `setContentOffset(_:animated:)`
    /// — qui fonctionne même quand `isScrollEnabled = false`, contrairement au
    /// `ScrollViewProxy.scrollTo` qui peut être bloqué par `.scrollDisabled(...)`.
    @Published var underlyingScrollView: UIScrollView?
    /// Niveaux de densité discrets, du plus grand format (1 colonne) à la vue
    /// ultra-dense. Le pinch fait passer d'un cran au cran adjacent.
    static let zoomLevels = [1, 3, 5, 7]
    /// Niveau affiché à l'ouverture (3 colonnes).
    static let defaultZoomLevelIndex = 1
    /// Seuil d'échelle au-delà duquel écarter les doigts fige la grille sur un
    /// niveau plus grand (moins de colonnes).
    let zoomInCommitThreshold: CGFloat = 1.35
    /// Seuil d'échelle en deçà duquel pincer fige la grille sur un niveau plus
    /// dense (plus de colonnes).
    let zoomOutCommitThreshold: CGFloat = 0.78

    /// Nombre de colonnes du niveau de densité courant.
    var columnCount: Int { Self.zoomLevels[zoomLevelIndex] }

    init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
    }

    func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
