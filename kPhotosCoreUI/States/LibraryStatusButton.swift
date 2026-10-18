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

public enum LibraryStatusTone {
    case neutral
    case active
    case success
    case attention

    public var color: Color {
        switch self {
        case .neutral, .active: return .primary
        case .success: return .green
        case .attention: return .orange
        }
    }
}

public struct LibraryStatusGlyph: View {
    private let symbol: String
    private let tone: LibraryStatusTone
    private let progress: Double?
    private let size: CGFloat

    public init(symbol: String, tone: LibraryStatusTone, progress: Double? = nil, size: CGFloat = 36) {
        self.symbol = symbol; self.tone = tone; self.progress = progress; self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(tone.color.opacity(0.06))
            if let progress {
                Circle().stroke(tone.color.opacity(0.1), lineWidth: 2)
                Circle().trim(from: 0, to: max(0, min(progress, 1)))
                    .stroke(tone.color.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(tone.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// An entry to details, kept inside scroll content alongside the photos.
public struct LibraryStatusButton: View {
    private let title: String
    private let subtitle: String
    private let symbol: String
    private let tone: LibraryStatusTone
    private let progress: Double?
    private let action: () -> Void

    public init(
        title: String,
        subtitle: String,
        symbol: String,
        tone: LibraryStatusTone,
        progress: Double? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.tone = tone; self.progress = progress; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LibraryStatusGlyph(symbol: symbol, tone: tone, progress: progress)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
