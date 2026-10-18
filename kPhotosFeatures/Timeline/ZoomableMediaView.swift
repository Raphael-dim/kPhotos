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

// MARK: - ZoomableScrollView

/// UIScrollView wrappé en UIViewRepresentable pour le zoom pinch natif.
/// Quand zoomScale == 1, le pan interne ne défile pas (le contenu tient dans
/// le cadre) : le geste de pagination/dismiss du parent reste donc seul maître.
/// Quand zoomScale > 1, le pan de l'UIScrollView prend la priorité.
///
/// `onZoomChange` est appelé à chaque variation du zoom (utilisé par le parent
/// pour désactiver le geste swipe-to-dismiss tant que la photo est zoomée).
struct ZoomableScrollView: UIViewRepresentable {
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
final class ScrollContainer: UIView {
    let scrollView = UIScrollView()
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

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

        let fitSize = if imageRatio > boundsRatio {
            CGSize(width: boundsSize.width, height: boundsSize.width / imageRatio)
        } else {
            CGSize(width: boundsSize.height * imageRatio, height: boundsSize.height)
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
