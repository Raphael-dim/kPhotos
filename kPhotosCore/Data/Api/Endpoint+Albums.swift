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

/// Endpoints "albums" — implémentés sur les **catégories kDrive** natives.
///
/// Pourquoi des catégories et pas des dossiers : une catégorie est une étiquette
/// N:N attachée à un fichier sans le déplacer. Une photo peut donc être dans
/// plusieurs albums et reste à son emplacement chronologique. Cf. spec OpenAPI
/// `/2/drive/{drive_id}/categories*`.
public extension Endpoint {
    /// `GET` (liste) et `POST` (création) sur l'ensemble des catégories du drive.
    static func categories(driveId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/categories")
    }

    /// `PUT` (renommer / changer couleur) et `DELETE` sur une catégorie.
    static func category(driveId: Int, categoryId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/categories/\(categoryId)")
    }

    /// `POST` (attacher) et `DELETE` (détacher) une catégorie sur un fichier unique.
    static func fileCategory(driveId: Int, fileId: Int, categoryId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)/categories/\(categoryId)")
    }

    /// `POST` / `DELETE` bulk : attache ou détache la catégorie sur N fichiers
    /// en un seul appel — body `{ "file_ids": [Int] }`.
    static func filesCategory(driveId: Int, categoryId: Int) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/categories/\(categoryId)")
    }

    /// `GET` paginé : liste les fichiers portant la catégorie. Cursor v3.
    static func categoryFiles(driveId: Int, categoryId: Int, cursor: String? = nil, limit: Int = 100) -> Endpoint {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return Endpoint(path: "/3/drive/\(driveId)/categories/\(categoryId)/files", queryItems: items)
    }
}
