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

import kPhotosResources
import SwiftUI
import UIKit

/// A full-height edge target keeps fast scrolling separate from the grid's
/// long-press selection gesture. The scroll view remains the source of truth.
struct TimelineFastScroller: UIViewRepresentable {
    let scrollView: UIScrollView?

    func makeUIView(context: Context) -> FastScrollerControl {
        FastScrollerControl()
    }

    func updateUIView(_ control: FastScrollerControl, context: Context) {
        control.attach(to: scrollView)
    }
}

final class FastScrollerControl: UIControl {
    private weak var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private let track = UIView()
    private let thumb = UIView()
    private var grabOffset: CGFloat = 0
    private var isScrubbing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        track.isUserInteractionEnabled = false
        thumb.isUserInteractionEnabled = false
        track.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.18)
        addSubview(track)
        addSubview(thumb)
        isAccessibilityElement = true
        accessibilityLabel = L10n.Timeline.fastScroll
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func attach(to scrollView: UIScrollView?) {
        guard self.scrollView !== scrollView else { return }
        offsetObservation = nil
        sizeObservation = nil
        self.scrollView = scrollView
        offsetObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.updateThumb()
        }
        sizeObservation = scrollView?.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            self?.updateThumb()
        }
        updateThumb()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateThumb()
    }

    private var offsetRange: ClosedRange<CGFloat>? {
        guard let scrollView else { return nil }
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(
            minimum,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        guard maximum - minimum > 1 else { return nil }
        return minimum ... maximum
    }

    private func updateThumb() {
        guard let scrollView, let range = offsetRange, bounds.height > 0 else {
            track.isHidden = true
            thumb.isHidden = true
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            return
        }
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        track.isHidden = false
        thumb.isHidden = false

        let trackHeight = max(1, bounds.height - 16)
        let contentHeight = scrollView.contentSize.height
            + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom
        let thumbHeight = min(trackHeight, max(52, trackHeight * scrollView.bounds.height / contentHeight))
        let fraction = min(1, max(
            0,
            (scrollView.contentOffset.y - range.lowerBound)
                / (range.upperBound - range.lowerBound)
        ))
        let thumbWidth: CGFloat = isScrubbing ? 10 : 6
        track.frame = CGRect(x: bounds.width - 13, y: 8, width: 4, height: trackHeight)
        track.layer.cornerRadius = 2
        thumb.frame = CGRect(
            x: bounds.width - 11 - thumbWidth / 2,
            y: 8 + fraction * (trackHeight - thumbHeight),
            width: thumbWidth,
            height: thumbHeight
        )
        thumb.layer.cornerRadius = thumbWidth / 2
        thumb.backgroundColor = isScrubbing ? tintColor : .secondaryLabel
        accessibilityValue = NumberFormatter.localizedString(from: NSNumber(value: Double(fraction)), number: .percent)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard offsetRange != nil else { return false }
        let point = touch.location(in: self)
        let grabsThumb = thumb.frame.insetBy(dx: -18, dy: -22).contains(point)
        grabOffset = grabsThumb ? point.y - thumb.frame.minY : thumb.frame.height / 2
        isScrubbing = true
        updateThumb()
        if !grabsThumb { scroll(to: point.y) }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        scroll(to: touch.location(in: self).y)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        isScrubbing = false
        updateThumb()
    }

    override func cancelTracking(with event: UIEvent?) {
        isScrubbing = false
        updateThumb()
    }

    private func scroll(to touchY: CGFloat) {
        guard let scrollView, let range = offsetRange else { return }
        let travel = max(1, track.bounds.height - thumb.bounds.height)
        let fraction = min(1, max(0, (touchY - grabOffset - track.frame.minY) / travel))
        let offsetY = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
    }

    override func accessibilityIncrement() {
        scrollByPage(1)
    }

    override func accessibilityDecrement() {
        scrollByPage(-1)
    }

    private func scrollByPage(_ direction: CGFloat) {
        guard let scrollView, let range = offsetRange else { return }
        let target = min(range.upperBound, max(
            range.lowerBound,
            scrollView.contentOffset.y + direction * scrollView.bounds.height
        ))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: true)
    }
}
