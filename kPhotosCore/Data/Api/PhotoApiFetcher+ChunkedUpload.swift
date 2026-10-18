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
import CryptoKit
import Foundation
import Security

struct ChunkUploadSession: Codable {
    let token: String
    let uploadURL: URL
    let startedAt: Date
    var nextChunk: Int
}

/// Session tokens stay in the Keychain; an interrupted background task can resume.
enum ChunkSessionStorage {
    static func read(_ key: String) throws -> ChunkUploadSession? {
        var query = base(key)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PhotoAPIError.invalidResponse }
        return try JSONDecoder().decode(ChunkUploadSession.self, from: data)
    }

    static func save(
        _ session: ChunkUploadSession,
        key: String
    ) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PhotoAPIError.invalidResponse }
        var query = base(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw PhotoAPIError.invalidResponse }
    }

    static func remove(_ key: String) { SecItemDelete(base(key) as CFDictionary) }
    private static func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.kphotos.uploads",
            kSecAttrAccount as String: key
        ]
    }
}

struct ChunkSessionResponse: Decodable {
    let result: Bool
    let token: String?
    let uploadURL: URL?
    let file: RemoteFileDTO?
    enum CodingKeys: String, CodingKey { case result, token, file; case uploadURL = "upload_url" }
}

extension PhotoApiFetcher {
    static let chunkSize = 50_000_000

    static func trustedUploadHost(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".infomaniak.com") || host.hasSuffix(".infomaniakusercontent.com")
    }

    func uploadChunked(
        driveId: Int,
        folderId: String,
        source: UploadSource,
        createdAt: Date,
        totalSize: Int,
        clientToken: String
    ) async throws -> RemoteFileDTO {
        let fileURL = source.fileURL

        guard totalSize <= 50_000_000_000 else { throw BackupSafetyError.tooLarge }
        guard let directoryId = Int(folderId) else { throw PhotoAPIError.invalidResponse }
        let key = MediaIntegrity.token("\(driveId):\(folderId):\(clientToken):\(totalSize)")
        var stored = try ChunkSessionStorage.read(key)
        if let old = stored, Date().timeIntervalSince(old.startedAt) >= 4 * 3600 {
            // Expired sessions are canceled by kDrive itself, never delete the resulting file.
            ChunkSessionStorage.remove(key); stored = nil
        }
        let chunks = (totalSize + Self.chunkSize - 1) / Self.chunkSize
        if stored == nil {
            stored = try await startChunkedUpload(
                source: source,
                driveId: driveId,
                directoryId: directoryId,
                createdAt: createdAt,
                totalSize: totalSize,
                key: key
            )
        }
        guard var upload = stored, Self.trustedUploadHost(upload.uploadURL) else { throw PhotoAPIError.invalidResponse }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        for number in upload.nextChunk ... max(upload.nextChunk, chunks) where number <= chunks {
            try Task.checkCancellation()
            let offset = (number - 1) * Self.chunkSize
            try handle.seek(toOffset: UInt64(offset))
            let expectedSize = min(Self.chunkSize, totalSize - offset)
            guard let data = try handle.read(upToCount: expectedSize), data.count == expectedSize else {
                throw BackupSafetyError.integrity
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let endpoint = Endpoint(
                baseURL: upload.uploadURL,
                path: "/3/drive/\(driveId)/upload/session/\(upload.token)/chunk",
                queryItems: [
                    URLQueryItem(name: "chunk_number", value: String(number)),
                    URLQueryItem(name: "chunk_size", value: String(data.count)),
                    URLQueryItem(name: "chunk_hash", value: "sha256:" + digest)
                ]
            )
            try await sendChunk(data, to: endpoint)
            upload.nextChunk = number + 1
            try ChunkSessionStorage.save(
                upload,
                key: key
            )
        }
        let finished: ChunkSessionResponse = try await requestJSON(
            endpoint: Endpoint(path: "/3/drive/\(driveId)/upload/session/\(upload.token)/finish"),
            method: .post,
            parameters: ["created_at": Int(createdAt.timeIntervalSince1970)]
        )
        guard finished.result, let file = finished.file, file.size == totalSize else { throw BackupSafetyError.integrity }
        ChunkSessionStorage.remove(key)
        return file
    }

    private func startChunkedUpload(
        source: UploadSource,
        driveId: Int,
        directoryId: Int,
        createdAt: Date,
        totalSize: Int,
        key: String
    ) async throws -> ChunkUploadSession {
        let fileName = source.fileName
        let chunks = (totalSize + Self.chunkSize - 1) / Self.chunkSize
        let response: ChunkSessionResponse = try await requestJSON(
            endpoint: Endpoint(path: "/3/drive/\(driveId)/upload/session/start"),
            method: .post,
            parameters: [
                "directory_id": directoryId,
                "file_name": fileName,
                "total_size": totalSize,
                "total_chunks": chunks,
                "created_at": Int(createdAt.timeIntervalSince1970),
                "conflict": "error"
            ]
        )
        guard response.result, let token = response.token, let url = response.uploadURL,
              Self.trustedUploadHost(url) else { throw PhotoAPIError.invalidResponse }
        let session = ChunkUploadSession(token: token, uploadURL: url, startedAt: Date(), nextChunk: 1)
        try ChunkSessionStorage.save(
            session,
            key: key
        )
        return session
    }

    private func sendChunk(_ data: Data, to endpoint: Endpoint) async throws {
        try await performWithRetry {
            try await self.waitForRequest()
            let response = await self.session.upload(
                data,
                to: endpoint.url,
                method: .post,
                headers: ["Content-Type": "application/octet-stream"]
            )
            .validate()
            .serializingData()
            .response
            try Task.checkCancellation()
            if let error = response.error { throw Self.mapAFError(error, statusCode: response.response?.statusCode) }
            guard let body = response.data,
                  let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  envelope["result"] as? String == "success" else { throw PhotoAPIError.invalidResponse }
        }
    }
}
