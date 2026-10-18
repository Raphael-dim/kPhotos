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

extension TimelineGridInteraction {
    func handlePinchBegan(_ sample: PinchSample) {
        // Pas de pinch pendant un drag-select : un second doigt accidentel ne
        // doit pas redimensionner la grille pendant l'affinage d'une sélection.
        guard dragSelectAnchorId == nil else { return }
        isPinching = true
        gestureScale = 1.0
        pinchArmedForCommit = false
        gestureAnchor = UnitPoint(x: 0.5, y: sample.anchorUnitY)
        pinchAnchorViewportFraction = sample.viewportFraction
        pinchAnchorTileId = tileFrames
            .first(where: { $0.value.contains(sample.globalLocation) })?.key
    }

    /// Glissement des doigts : on applique l'échelle homothétique en direct et
    /// on joue un petit cran haptique au franchissement du seuil de bascule —
    /// le geste « prépare » visuellement la transition vers le niveau voisin.
    func handlePinchChanged(_ sample: PinchSample) {
        guard isPinching else { return }
        let scale = clampedGestureScale(sample.scale)
        gestureScale = scale
        let armed = commitTarget(for: scale) != zoomLevelIndex
        if armed != pinchArmedForCommit {
            pinchArmedForCommit = armed
            if armed { hapticFeedback(.soft) }
        }
    }

    /// Fin du pinch : si le seuil a été franchi, on se fige sur le niveau voisin
    /// et on recentre le scroll sur l'épicentre ; sinon ressort inverse qui
    /// ramène la grille à son état initial exact.
    func handlePinchEnded(_ sample: PinchSample, scrollProxy: ScrollViewProxy) {
        guard isPinching else { return }
        isPinching = false
        pinchArmedForCommit = false

        let finalScale = clampedGestureScale(sample.scale)
        let target = commitTarget(for: finalScale)
        let settle = Animation.spring(response: 0.34, dampingFraction: 0.82)

        if target != zoomLevelIndex {
            hapticFeedback(.rigid)
            let anchorId = pinchAnchorTileId
            let viewportFraction = pinchAnchorViewportFraction
            // Le changement de niveau et la remise à l'échelle 1.0 sont animés
            // ensemble : la taille rendue (layout × échelle) varie de façon
            // monotone, donc la bascule se lit comme un zoom continu sans à-coup.
            withAnimation(settle) {
                zoomLevelIndex = target
                gestureScale = 1.0
                // Recentrage : la tile visée au début du geste revient sous
                // l'épicentre malgré la réorganisation complète de la grille.
                if let anchorId {
                    scrollProxy.scrollTo(
                        anchorId,
                        anchor: UnitPoint(x: 0.5, y: viewportFraction)
                    )
                }
            }
        } else {
            // Seuil non atteint : ressort inverse, la grille reprend son état exact.
            withAnimation(settle) { gestureScale = 1.0 }
        }
        pinchAnchorTileId = nil
    }

    /// Niveau de densité visé pour une échelle donnée. Renvoie le niveau courant
    /// quand aucun seuil n'est franchi (ou qu'il n'existe pas de cran au-delà).
    func commitTarget(for scale: CGFloat) -> Int {
        let lastIndex = Self.zoomLevels.count - 1
        if scale >= zoomInCommitThreshold, zoomLevelIndex > 0 {
            return zoomLevelIndex - 1
        }
        if scale <= zoomOutCommitThreshold, zoomLevelIndex < lastIndex {
            return zoomLevelIndex + 1
        }
        return zoomLevelIndex
    }

    /// Borne l'échelle du geste. Aux niveaux extrêmes, écarter ou pincer « dans
    /// le vide » ne donne qu'un léger jeu élastique signalant la butée.
    func clampedGestureScale(_ raw: CGFloat) -> CGFloat {
        let canZoomIn = zoomLevelIndex > 0
        let canZoomOut = zoomLevelIndex < Self.zoomLevels.count - 1
        let upperLimit: CGFloat = canZoomIn ? 2.4 : 1.08
        let lowerLimit: CGFloat = canZoomOut ? 0.45 : 0.94
        return min(max(raw, lowerLimit), upperLimit)
    }
}
