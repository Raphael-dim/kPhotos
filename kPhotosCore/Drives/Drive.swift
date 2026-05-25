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

import Foundation
import RealmSwift

public final class Drive: Object {
    @Persisted(primaryKey: true) public var id: Int = 0
    @Persisted public var name: String = ""
    @Persisted public var size: Int64 = 0
    @Persisted public var usedSize: Int64 = 0
    @Persisted public var role: String = ""
    @Persisted public var isInMaintenance: Bool = false
    @Persisted public var isSelected: Bool = false

    /// ID de l'espace `Private` du drive (visibility="is_private_space").
    /// La racine kDrive (id=1) n'est PAS writable — c'est un conteneur système.
    /// L'écriture doit cibler l'espace Private. Découvert au premier sync, mis en cache.
    @Persisted public var privateSpaceId: String = ""

    /// ID du dossier racine `kPhotos/` une fois créé dans Private. Mis en cache.
    @Persisted public var rootFolderId: String = ""
}

/// Représentation thread-safe d'un `Drive`. Construite dans un block Realm puis
/// renvoyée à travers les frontières async — jamais d'objet managé qui traverse.
/// Cf. AGENTS.md §21 (Realm thread-safety).
public struct DriveSnapshot: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int64
    public let usedSize: Int64
    public let role: String
    public let isInMaintenance: Bool
    public let isSelected: Bool
    public let privateSpaceId: String
    public let rootFolderId: String

    public init(id: Int,
                name: String,
                size: Int64,
                usedSize: Int64,
                role: String,
                isInMaintenance: Bool,
                isSelected: Bool,
                privateSpaceId: String,
                rootFolderId: String) {
        self.id = id
        self.name = name
        self.size = size
        self.usedSize = usedSize
        self.role = role
        self.isInMaintenance = isInMaintenance
        self.isSelected = isSelected
        self.privateSpaceId = privateSpaceId
        self.rootFolderId = rootFolderId
    }

    init(_ drive: Drive) {
        self.init(
            id: drive.id,
            name: drive.name,
            size: drive.size,
            usedSize: drive.usedSize,
            role: drive.role,
            isInMaintenance: drive.isInMaintenance,
            isSelected: drive.isSelected,
            privateSpaceId: drive.privateSpaceId,
            rootFolderId: drive.rootFolderId
        )
    }
}
