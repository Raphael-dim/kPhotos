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
import SwiftUI
import UIKit

extension TimelineGridInteraction {
    var orderedTileIds: [String] {
        guard case .ready(_, let sections) = viewModel.state else { return [] }
        return sections.flatMap { $0.items.map(\.id) }
    }

    /// Geste maître : `LongPress(0.5s).sequenced(before: Drag)` au niveau ScrollView.
    /// `.simultaneousGesture` permet la coexistence avec le pan natif d'UIScrollView,
    /// d'où le scroll continue de fonctionner pendant les 500ms d'attente. Quand le
    /// long-press confirme (doigt resté stable assez longtemps), la phase drag se
    /// met en place et notre handler hit-teste la tile sous le doigt pour l'utiliser
    /// comme anchor — puis chaque mouvement étend ou rétracte la plage.

    /// Appelé pour chaque événement de la phase drag. Le premier appel matérialise
    /// l'ancrage : on hit-teste pour trouver la tile sous le doigt à ce moment-là,
    /// haptique de confirmation, snapshot de la sélection courante. Les suivants
    /// étendent la plage `[anchor, current]` dans l'ordre chronologique.
    func handleDragChange(at globalLocation: CGPoint, scrollProxy: ScrollViewProxy) {
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

    func handleDragEnded() {
        dragSelectAnchorId = nil
        dragSelectInitialSelection = []
        lastDragLocation = nil
        stopAutoScroll()
    }

    /// Recalcule `selection = snapshot ∪ [anchor, current]` à partir de la
    /// position globale du doigt. Si aucune tile n'est sous le doigt (drag
    /// dans une zone vide), on conserve la dernière sélection.
    func updateRangeSelection(at globalLocation: CGPoint) {
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
    var autoScrollReferenceFrame: CGRect {
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
    func evaluateAutoScroll(at globalLocation: CGPoint, scrollProxy: ScrollViewProxy) {
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

    func startAutoScroll(direction: AutoScrollDirection, intensity: CGFloat, scrollProxy: ScrollViewProxy) {
        autoScrollDirection = direction
        autoScrollIntensity = intensity
        guard autoScrollTimer == nil else { return }
        // Tick à 30fps — granularité suffisante pour un défilement fluide sans
        // saturer le main thread (hit-test + scrollTo à chaque tick).
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performAutoScrollStep(scrollProxy: scrollProxy)
            }
        }
    }

    func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollRowAccumulator = 0
    }

    /// Avance la position de scroll d'un nombre fractionnaire de rows par tick,
    /// proportionnel à l'intensité. Un accumulateur évite de perdre la fraction
    /// d'un tick au suivant à faible intensité. Après le scroll, on recalcule
    /// la sélection à partir de la dernière position connue du doigt — les
    /// tiles ont bougé sous le doigt, donc le hit-test donne un résultat différent.
    func performAutoScrollStep(scrollProxy: ScrollViewProxy) {
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
