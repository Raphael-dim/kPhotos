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

struct ScrollViewIntrospector: UIViewRepresentable {
    let onFound: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView() {
                onFound(scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // En cas de re-layout / changement de hiérarchie, on retente la
        // résolution (idempotent côté appelant grâce au check d'identité).
        DispatchQueue.main.async {
            if let scrollView = uiView.enclosingScrollView() {
                onFound(scrollView)
            }
        }
    }
}

private extension UIView {
    /// Remonte la chaîne `superview` jusqu'à trouver un `UIScrollView`.
    /// `nil` si aucun ancêtre n'en est un (cas pathologique d'une vue détachée).
    func enclosingScrollView() -> UIScrollView? {
        var node: UIView? = superview
        while let current = node {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            node = current.superview
        }
        return nil
    }
}

// MARK: - PinchZoomDetector

/// Échantillon d'un événement de pinch, déjà projeté dans des repères
/// directement exploitables par la grille — l'appelant n'a aucune conversion de
/// coordonnées à faire.
struct PinchSample {
    /// Facteur d'échelle cumulé depuis le début du geste (1.0 au tout début).
    let scale: CGFloat
    /// Position verticale de l'épicentre dans le contenu, normalisée [0, 1] —
    /// utilisable telle quelle comme ancre `y` d'un `.scaleEffect`.
    let anchorUnitY: CGFloat
    /// Position verticale de l'épicentre dans le viewport, normalisée [0, 1].
    let viewportFraction: CGFloat
    /// Point médian des deux doigts en coordonnées globales (fenêtre) — pour
    /// hit-tester la tile située sous l'épicentre.
    let globalLocation: CGPoint
}

/// Sonde invisible qui branche un `UIPinchGestureRecognizer` sur l'`UIScrollView`
/// sous-jacent à la `ScrollView` SwiftUI parente. C'est le seul moyen fiable, sur
/// iOS 16, d'obtenir le point médian des deux doigts (l'épicentre du geste) :
/// `MagnificationGesture` ne l'expose pas, et `MagnifyGesture` (qui le ferait via
/// `startAnchor`) n'existe qu'à partir d'iOS 17.
///
/// Le recognizer est posé en reconnaissance simultanée pour cohabiter avec le pan
/// natif et les gestes SwiftUI. Le pan natif est restreint à un seul doigt, si
/// bien qu'un pinch (deux doigts) ne déclenche jamais de défilement parasite.
struct PinchZoomDetector: UIViewRepresentable {
    let onBegan: (PinchSample) -> Void
    let onChanged: (PinchSample) -> Void
    let onEnded: (PinchSample) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        // La vue n'est pas encore montée dans la hiérarchie à cet instant —
        // on diffère la résolution de l'`UIScrollView` d'un cycle de layout.
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView() {
                context.coordinator.attach(to: scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Rafraîchit les closures pour que le recognizer appelle toujours la
        // dernière version (capturant l'état SwiftUI courant).
        context.coordinator.parent = self
        if context.coordinator.scrollView == nil {
            DispatchQueue.main.async {
                if let scrollView = uiView.enclosingScrollView() {
                    context.coordinator.attach(to: scrollView)
                }
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PinchZoomDetector
        weak var scrollView: UIScrollView?

        init(_ parent: PinchZoomDetector) {
            self.parent = parent
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView == nil else { return }
            self.scrollView = scrollView
            // Le pan natif ne réagit plus qu'à un doigt : un pinch (deux doigts)
            // ne provoque donc jamais de défilement parasite pendant le zoom.
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handlePinch(_:))
            )
            pinch.delegate = self
            scrollView.addGestureRecognizer(pinch)
        }

        @objc
        private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView else { return }
            let viewportHeight = scrollView.bounds.height
            let contentHeight = scrollView.contentSize.height
            guard viewportHeight > 0, contentHeight > 0 else { return }

            // `location(in: scrollView)` est déjà en coordonnées de contenu :
            // l'origine du repère d'un `UIScrollView` suit son `contentOffset`.
            let contentY = recognizer.location(in: scrollView).y
            let offsetY = scrollView.contentOffset.y
            let sample = PinchSample(
                scale: recognizer.scale,
                anchorUnitY: min(max(contentY / contentHeight, 0), 1),
                viewportFraction: min(max((contentY - offsetY) / viewportHeight, 0), 1),
                globalLocation: recognizer.location(in: nil)
            )

            switch recognizer.state {
            case .began:
                parent.onBegan(sample)
            case .changed:
                parent.onChanged(sample)
            case .ended, .cancelled, .failed:
                parent.onEnded(sample)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
