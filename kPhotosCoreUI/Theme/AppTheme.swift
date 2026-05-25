/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

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

/// Préférence d'apparence choisie par l'utilisateur. Persistée via `@AppStorage`
/// sous `AppTheme.storageKey` et appliquée au `WindowGroup` avec
/// `.preferredColorScheme`. Le `String` raw value est requis par `@AppStorage`.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let storageKey = "appTheme"

    public var id: String { rawValue }

    /// `nil` laisse iOS suivre le réglage d'apparence du système.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public var label: String {
        switch self {
        case .system: L10n.Settings.themeSystem
        case .light: L10n.Settings.themeLight
        case .dark: L10n.Settings.themeDark
        }
    }
}
