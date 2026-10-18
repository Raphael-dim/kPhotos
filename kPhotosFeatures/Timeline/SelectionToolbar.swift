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

/// Toolbar du mode sélection — pilule glass flottante au-dessus de la safe area.
/// Style proche d'une notification iOS : `ultraThinMaterial` + fin liseré +
/// ombre douce. Sur iOS 26+, on passe au matériau Liquid Glass natif via
/// `glassEffect`. Le compteur est volontairement minimaliste (juste le nombre,
/// sans label) pour rester discret et laisser la place aux actions.
struct SelectionToolbar: View {
    let selectedCount: Int
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onDownload: () -> Void
    let onAddToAlbum: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Annuler — chevron / croix à gauche.
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }

            // Compteur discret : juste le nombre, sans label "selected".
            // `monospacedDigit` évite que la pilule respire quand le compteur
            // passe de 9 → 10 → 99 → 100.
            Text(selectedCount, format: .number)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: selectedCount)

            Spacer(minLength: 8)

            // Actions à droite, dans l'ordre attendu iOS (ranger → exporter → supprimer).
            actionButton(systemImage: "folder", tint: .primary, action: onAddToAlbum)
            actionButton(systemImage: "square.and.arrow.down", tint: .primary, action: onDownload)
            actionButton(systemImage: "trash", tint: .red, action: onDelete)
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .glassCapsule()
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func actionButton(systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
    }
}

// MARK: - Glass capsule helper

private extension View {
    /// Pilule glass hybride : Liquid Glass natif sur iOS 26+ (matériau adaptatif
    /// avec reflets et distorsions), fallback `ultraThinMaterial` + fin liseré
    /// sur iOS 16-25. `glassEffect` n'existe que dans le SDK Swift 6.2 (Xcode 26),
    /// d'où le `#if compiler(>=6.2)` qui évite un échec de compilation sur des
    /// toolchains plus anciennes.
    @ViewBuilder
    func glassCapsule() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
                )
        }
        #else
        background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
            )
        #endif
    }
}

#Preview {
    ZStack {
        // Fond varié pour rendre l'effet glass visible en preview.
        LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

        VStack {
            Spacer()
            SelectionToolbar(
                selectedCount: 12,
                onCancel: {},
                onDelete: {},
                onDownload: {},
                onAddToAlbum: {}
            )
        }
    }
}
