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

import Foundation

public extension Endpoint {
    /// Liste les enfants d'un dossier en pagination cursor (cf. spec OpenAPI :
    /// `GET /3/drive/{drive_id}/files/{file_id}/files`).
    /// Le v3 n'accepte plus `page`/`per_page` — utiliser `cursor`/`limit`.
    static func listFolder(driveId: Int, folderId: String, cursor: String? = nil, limit: Int = 100) -> Endpoint {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return Endpoint(path: "/3/drive/\(driveId)/files/\(folderId)/files", queryItems: items)
    }

    /// Upload simple (≤ 1 GB côté API, cf. spec OpenAPI v3). Métadonnées en
    /// **query params**, body en octet-stream.
    /// Cf. docs/api/infomaniak_openapi.json — `POST /3/drive/{drive_id}/upload`.
    ///
    /// `clientToken` est l'idempotency key documentée (16-36 chars, pattern `[\w!-]+`).
    /// Indispensable pour les retry : si l'app a perdu la réponse d'un upload qui a
    /// pourtant réussi côté serveur, rejouer la même requête avec le même token
    /// retourne le fichier déjà créé au lieu d'en créer un doublon.
    /// L'appelant doit générer un UUID stable par `BackupItem.localIdentifier` et le
    /// persister tant que l'upload n'a pas confirmé son issue.
    static func upload(
        driveId: Int,
        directoryId: String,
        fileName: String,
        totalSize: Int,
        createdAt: Int,
        clientToken: String,
        conflict: String = "error"
    ) -> Endpoint {
        Endpoint(
            path: "/3/drive/\(driveId)/upload",
            queryItems: [
                URLQueryItem(name: "directory_id", value: directoryId),
                URLQueryItem(name: "file_name", value: fileName),
                URLQueryItem(name: "total_size", value: String(totalSize)),
                URLQueryItem(name: "created_at", value: String(createdAt)),
                URLQueryItem(name: "client_token", value: clientToken),
                URLQueryItem(name: "conflict", value: conflict)
            ]
        )
    }

    /// Endpoint preview kDrive. Sans paramètres, retourne un preview "par défaut"
    /// (petit, suffisant pour des vignettes). Avec `width`/`height`/`quality`,
    /// on récupère un preview HD adapté au plein écran.
    static func preview(
        driveId: Int,
        fileId: String,
        width: Int? = nil,
        height: Int? = nil,
        quality: Int? = nil
    ) -> Endpoint {
        var items: [URLQueryItem] = []
        if let width { items.append(URLQueryItem(name: "width", value: String(width))) }
        if let height { items.append(URLQueryItem(name: "height", value: String(height))) }
        if let quality { items.append(URLQueryItem(name: "quality", value: String(quality))) }
        return Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)/preview", queryItems: items)
    }

    static func thumbnail(driveId: Int, fileId: String, revision: String = "") -> Endpoint {
        let timestamps = revision.split(separator: ":").prefix(2).compactMap { Int($0) }
        let timestamp = timestamps.max().flatMap { $0 > 0 ? $0 : nil }
        let items = timestamp.map { [URLQueryItem(name: "t", value: String($0))] } ?? []
        return Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)/thumbnail", queryItems: items)
    }

    static func download(driveId: Int, fileId: String) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)/download")
    }

    static func delete(driveId: Int, fileId: String) -> Endpoint {
        Endpoint(path: "/2/drive/\(driveId)/files/\(fileId)")
    }

    static func fileInfo(driveId: Int, fileId: String) -> Endpoint {
        Endpoint(path: "/3/drive/\(driveId)/files/\(fileId)")
    }

    static func search(driveId: Int, type: String = "image", cursor: String? = nil, limit: Int = 100) -> Endpoint {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return Endpoint(path: "/3/drive/\(driveId)/files/search", queryItems: items)
    }
}
