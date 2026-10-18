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

import Alamofire
import Foundation

public extension PhotoApiFetcher {
    /// Upload simple (≤ 50 MB), puis upload par blocs au-delà.
    /// **Format requis par l'API** (cf. docs/api/infomaniak_openapi.json — `/3/drive/{drive_id}/upload`) :
    /// - Content-Type `application/octet-stream`
    /// - Toutes les métadonnées en **query params** (PAS de multipart)
    ///
    /// `createdAt` est OBLIGATOIRE pour préserver la date de prise de vue (cf. AGENTS.md §6).
    /// kDrive accepte et stocke fidèlement cette date (vérifié empiriquement, cf. scripts/api_test_advanced.sh T2).
    ///
    /// `clientToken` doit être stable par item de file d'attente — l'appelant le
    /// génère lors de l'enqueue (`BackupItem.clientToken`) et le rejoue tel quel
    /// sur chaque tentative. Le serveur déduplique : un retry après réponse perdue
    /// ne crée pas de doublon, il retourne le DTO du fichier déjà créé.
    func upload(
        driveId: Int,
        folderId: String,
        fileURL: URL,
        fileName: String,
        createdAt: Date,
        mimeType: String,
        clientToken: String
    ) async throws -> RemoteFileDTO {
        let createdAtUnix = Int(createdAt.timeIntervalSince1970)
        let totalSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        if totalSize > Self.chunkSize {
            return try await uploadChunked(
                driveId: driveId,
                folderId: folderId,
                fileURL: fileURL,
                fileName: fileName,
                createdAt: createdAt,
                totalSize: totalSize,
                clientToken: clientToken
            )
        }
        return try await performWithRetry { [weak self] in
            guard let self else { throw PhotoAPIError.network(underlying: "fetcher deallocated") }
            return try await performUpload(
                driveId: driveId,
                folderId: folderId,
                fileURL: fileURL,
                fileName: fileName,
                createdAtUnix: createdAtUnix,
                totalSize: totalSize,
                mimeType: mimeType,
                clientToken: clientToken
            )
        }
    }

    private func performUpload(
        driveId: Int,
        folderId: String,
        fileURL: URL,
        fileName: String,
        createdAtUnix: Int,
        totalSize: Int,
        mimeType: String,
        clientToken: String
    ) async throws -> RemoteFileDTO {
        let endpoint = Endpoint.upload(
            driveId: driveId,
            directoryId: folderId,
            fileName: fileName,
            totalSize: totalSize,
            createdAt: createdAtUnix,
            clientToken: clientToken
        )
        try await waitForRequest()
        APILog.request(
            method: "POST",
            url: endpoint.url,
            body: "[binary \(totalSize) bytes] Content-Type: \(mimeType)"
        )
        let decoder = decoder
        let response = await session
            .upload(
                fileURL,
                to: endpoint.url,
                method: .post,
                headers: HTTPHeaders([HTTPHeader(name: "Content-Type", value: "application/octet-stream")])
            )
            .validate()
            .serializingDecodable(InfomaniakResponse<RemoteFileDTO>.self, decoder: decoder)
            .response
        try Task.checkCancellation()

        if let envelope = response.value {
            APILog.response(url: endpoint.url, statusCode: response.response?.statusCode, body: response.data)
            return envelope.data
        }

        if let error = response.error {
            throw Self.mapAFError(
                error,
                statusCode: response.response?.statusCode,
                url: endpoint.url,
                body: response.data
            )
        }

        throw PhotoAPIError.invalidResponse
    }
}
