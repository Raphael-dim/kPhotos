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
    /// Resolve the authenticated API redirect before handing the URL to AVPlayer.
    /// The player receives a short-lived signed URL, never the personal access token.
    func playbackURL(driveId: Int, fileId: String) async throws -> URL {
        try await signedOriginalURL(driveId: driveId, fileId: fileId, priority: 2)
    }

    internal func signedOriginalURL(driveId: Int, fileId: String, priority: Int) async throws -> URL {
        try await waitForRequest(priority: priority)
        let endpoint = Endpoint.download(driveId: driveId, fileId: fileId)
        APILog.request(method: "GET", url: endpoint.url, body: nil)
        let response = await session.request(endpoint.url)
            .redirect(using: Redirector(behavior: .doNotFollow))
            .validate(statusCode: 300 ..< 400)
            .serializingData(emptyResponseCodes: Set(300 ..< 400))
            .response
        try Task.checkCancellation()
        if let error = response.error {
            throw Self.mapAFError(error, statusCode: response.response?.statusCode)
        }
        guard let location = response.response?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: endpoint.url)?.absoluteURL,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw PhotoAPIError.invalidResponse
        }
        return url
    }

    func originalMetadata(driveId: Int, fileId: String, isVideo: Bool) async throws -> EmbeddedMediaMetadata {
        let url = try await signedOriginalURL(driveId: driveId, fileId: fileId, priority: 0)
        return try await withThrowingTaskGroup(of: EmbeddedMediaMetadata.self) { group in
            group.addTask {
                if isVideo {
                    let source = try RemoteMediaAsset(url: url, configuration: self.binaryReadConfiguration)
                    defer { source.cancel() }
                    return try await EmbeddedMediaMetadata.video(asset: source.asset)
                }
                return try await OriginalImageMetadataReader(configuration: self.binaryReadConfiguration).read(url: url)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 45_000_000_000)
                throw PhotoAPIError.network(underlying: "metadata-read-timeout")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw PhotoAPIError.invalidResponse }
            return result
        }
    }

    /// The caller owns the temporary file and must remove it after use.
    func downloadFile(driveId: Int, fileId: String) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await waitForRequest(priority: 1)
        let response = await session.download(
            downloadURL(driveId: driveId, fileId: fileId),
            to: { _, _ in (target, []) }
        )
        .validate()
        .serializingDownloadedFileURL()
        .response
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: target)
            throw CancellationError()
        }
        if let url = response.value { return url }
        try? FileManager.default.removeItem(at: target) // Failed download may have left a partial temporary file.
        if let error = response.error {
            throw Self.mapAFError(error, statusCode: response.response?.statusCode)
        }
        throw PhotoAPIError.invalidResponse
    }
}
