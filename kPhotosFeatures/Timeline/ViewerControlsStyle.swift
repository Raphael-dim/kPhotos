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

// MARK: - DownloadToast

enum DownloadToast: Equatable {
    case success
    /// Transporte le message localisé de l'erreur pour l'afficher directement.
    case failure(String)
}

struct DownloadToastBanner: View {
    let toast: DownloadToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isSuccess ? .green : .red)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var isSuccess: Bool { toast == .success }

    private var message: String {
        switch toast {
        case .success: L10n.Viewer.saveToLibrarySuccess
        case .failure(let msg): msg
        }
    }
}

// MARK: - Glass Pill Helper

extension View {
    @ViewBuilder
    func viewerControlStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
        } else {
            buttonStyle(.plain)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    /// Pilule glass hybride : sur iOS 26+ on bénéficie du nouveau matériau Liquid
    /// Glass (avec reflets et distorsions), sur iOS 16-25 on retombe sur
    /// `ultraThinMaterial` + liseré fin pour mimer l'effet. Le compilateur ne
    /// connaît `glassEffect` que si on build avec le SDK iOS 26+ ; on garde donc
    /// la branche en `#if compiler(>=6.2)` (Swift 6.2 = Xcode 26 = SDK iOS 26).
    @ViewBuilder
    func glassPill(in shape: some InsettableShape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        #else
        background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        #endif
    }
}
