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

public final class Album: Object {
    @Persisted(primaryKey: true) public var id: String = ""
    @Persisted public var driveId: Int = 0
    @Persisted public var name: String = ""
    @Persisted public var coverPhotoId: String = ""
    @Persisted public var photoCount: Int = 0
    @Persisted public var createdAt: Date = .init()
    @Persisted public var isShared: Bool = false
}

/// Représentation thread-safe d'un `Album`. Cf. AGENTS.md §21 (Realm thread-safety).
/// Construite à l'intérieur d'un block Realm puis renvoyée à travers les frontières async.
public struct AlbumSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let driveId: Int
    public let name: String
    public let coverPhotoId: String
    public let photoCount: Int
    public let createdAt: Date
    public let isShared: Bool

    public init(id: String,
                driveId: Int,
                name: String,
                coverPhotoId: String,
                photoCount: Int,
                createdAt: Date,
                isShared: Bool) {
        self.id = id
        self.driveId = driveId
        self.name = name
        self.coverPhotoId = coverPhotoId
        self.photoCount = photoCount
        self.createdAt = createdAt
        self.isShared = isShared
    }

    /// Construire depuis un Album Realm — n'utiliser qu'à l'intérieur d'un block `realm.read`.
    init(_ album: Album) {
        self.init(
            id: album.id,
            driveId: album.driveId,
            name: album.name,
            coverPhotoId: album.coverPhotoId,
            photoCount: album.photoCount,
            createdAt: album.createdAt,
            isShared: album.isShared
        )
    }
}
