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

public struct SelectionManager {
    public private(set) var selectedIds: Set<String> = []

    public init() {}

    public mutating func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    public mutating func select(_ id: String) {
        selectedIds.insert(id)
    }

    public mutating func deselect(_ id: String) {
        selectedIds.remove(id)
    }

    public mutating func clear() {
        selectedIds.removeAll()
    }

    /// Remplace l'intégralité de la sélection. Utilisé par le drag-to-select qui
    /// recalcule la sélection à chaque mouvement du doigt comme `initial ∪ range`,
    /// plutôt que d'opérer en select/deselect par item.
    public mutating func setAll(_ ids: Set<String>) {
        selectedIds = ids
    }

    public func isSelected(_ id: String) -> Bool {
        selectedIds.contains(id)
    }

    public var count: Int {
        selectedIds.count
    }

    public var isEmpty: Bool {
        selectedIds.isEmpty
    }
}
