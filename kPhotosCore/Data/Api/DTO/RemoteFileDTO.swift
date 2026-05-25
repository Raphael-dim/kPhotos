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

/// Enveloppe standard Infomaniak : `{ "result": "success", "data": <T>, ... }`.
/// Cf. github.com/Infomaniak/ios-core `ApiResponse`. On ne capture que `data` (les autres
/// champs — pagination, cursor, error — sont ignorés en silence par Decodable).
public struct InfomaniakResponse<T: Decodable>: Decodable {
    public let data: T
}

public struct RemoteFileDTO: Decodable, Equatable {
    public let id: String
    public let name: String
    public let type: String         // "file" | "dir"
    public let visibility: String   // ex: "is_private_space", "is_in_private_space", "is_shared_space"
    /// Date de prise de vue extraite des métadonnées EXIF (ou spécifiée à l'upload via
    /// `created_at` query param). **Souvent 0** pour les fichiers uploadés depuis le web
    /// sans EXIF (screenshots, etc.) — d'où la nécessité du fallback sur `addedAt`.
    public let createdAt: Int
    /// Date de premier upload sur kDrive — TOUJOURS présente côté serveur. Utilisée
    /// comme fallback quand `createdAt` est manquant (uploads web).
    public let addedAt: Int
    public let lastModifiedAt: Int
    public let mimeType: String
    public let size: Int64
    public let hasThumbnail: Bool
    public let parentId: String?

    public var isDirectory: Bool { type == "dir" }

    /// Meilleure date de prise de vue disponible. Chaîne de fallback :
    /// 1. `createdAt` (EXIF / metadata) si renseigné
    /// 2. `addedAt` (date d'upload) sinon — toujours présent côté kDrive
    /// 3. `lastModifiedAt` en ultime recours
    /// Évite la date 1970 pour les fichiers uploadés depuis le web sans EXIF.
    public var bestTakenAt: Int {
        if createdAt > 0 { return createdAt }
        if addedAt > 0 { return addedAt }
        return lastModifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case visibility
        case createdAt = "created_at"
        case addedAt = "added_at"
        case lastModifiedAt = "last_modified_at"
        case mimeType = "mime_type"
        case size
        case hasThumbnail = "has_thumbnail"
        case parentId = "parent_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeFlexibleId(from: c, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(String.self, forKey: .type)) ?? "file"
        visibility = (try? c.decode(String.self, forKey: .visibility)) ?? ""
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
        addedAt = (try? c.decode(Int.self, forKey: .addedAt)) ?? 0
        lastModifiedAt = (try? c.decode(Int.self, forKey: .lastModifiedAt)) ?? 0
        mimeType = (try? c.decode(String.self, forKey: .mimeType)) ?? ""
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
        hasThumbnail = (try? c.decode(Bool.self, forKey: .hasThumbnail)) ?? false
        if let parentInt = try? c.decode(Int.self, forKey: .parentId) {
            parentId = String(parentInt)
        } else {
            parentId = try? c.decode(String.self, forKey: .parentId)
        }
    }

    /// Memberwise init explicite (le `init(from decoder:)` ci-dessus supprime celui auto-généré).
    /// Utile pour les tests et la construction directe.
    public init(id: String,
                name: String,
                type: String = "file",
                visibility: String = "",
                createdAt: Int,
                addedAt: Int = 0,
                lastModifiedAt: Int,
                mimeType: String,
                size: Int64,
                hasThumbnail: Bool,
                parentId: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.visibility = visibility
        self.createdAt = createdAt
        self.addedAt = addedAt
        self.lastModifiedAt = lastModifiedAt
        self.mimeType = mimeType
        self.size = size
        self.hasThumbnail = hasThumbnail
        self.parentId = parentId
    }

    static func decodeFlexibleId<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> String {
        if let int = try? container.decode(Int.self, forKey: key) { return String(int) }
        if let str = try? container.decode(String.self, forKey: key) { return str }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "id is neither Int nor String"
        )
    }
}

public struct RemoteFileListDTO: Decodable {
    public let data: [RemoteFileDTO]
    /// Cursor pagination v3 (cf. spec OpenAPI). Si `hasMore`, refaire un GET avec `?cursor=<value>`.
    public let cursor: String?
    public let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case data
        case cursor
        case hasMore = "has_more"
    }
}

/// Réponse détaillée de `GET /3/drive/{drive_id}/files/{file_id}` (schema FileV3).
/// Étend les champs de base avec path, hash et extension_type — utiles pour la fiche info.
public struct RemoteFileDetailDTO: Decodable {
    public let id: String
    public let name: String
    public let path: String?
    public let size: Int64
    public let mimeType: String
    public let createdAt: Int
    public let addedAt: Int?
    public let lastModifiedAt: Int
    public let hash: String?
    public let extensionType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, path, size, hash
        case mimeType = "mime_type"
        case createdAt = "created_at"
        case addedAt = "added_at"
        case lastModifiedAt = "last_modified_at"
        case extensionType = "extension_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try RemoteFileDTO.decodeFlexibleId(from: c, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        path = try? c.decode(String.self, forKey: .path)
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
        mimeType = (try? c.decode(String.self, forKey: .mimeType)) ?? ""
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
        addedAt = try? c.decode(Int.self, forKey: .addedAt)
        lastModifiedAt = (try? c.decode(Int.self, forKey: .lastModifiedAt)) ?? 0
        hash = try? c.decode(String.self, forKey: .hash)
        extensionType = try? c.decode(String.self, forKey: .extensionType)
    }
}

/// Catégorie kDrive — modèle natif N:N entre fichiers et libellés.
/// Cf. spec OpenAPI : `GET /2/drive/{drive_id}/categories` et endpoints associés.
/// Utilisée pour matérialiser un "album" kPhotos sans déplacer les fichiers.
public struct RemoteCategoryDTO: Decodable, Equatable {
    public let id: Int
    public let name: String
    /// Couleur hexadécimale (ex: "#FF5733"). Optionnelle côté création — kDrive
    /// en attribue une par défaut.
    public let color: String?
    /// Timestamp Unix de création — absent sur certaines réponses (PUT), 0 en
    /// fallback pour rester déchiffrable.
    public let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try? c.decode(String.self, forKey: .color)
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
    }

    public init(id: Int, name: String, color: String? = nil, createdAt: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
    }
}

public struct RemoteDirectoryDTO: Decodable, Equatable {
    public let id: String
    public let name: String
    public let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try RemoteFileDTO.decodeFlexibleId(from: c, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
    }
}
