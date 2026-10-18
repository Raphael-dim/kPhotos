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
import os

/// Logger dédié au layer API. Filtre dans Xcode : subsystem `app.kphotos`, category `api`.
/// Console : `log stream --predicate 'subsystem == "app.kphotos"'`.
///
/// Les URL, identifiants, corps et réponses ne sont jamais journalisés.
/// Seuls la méthode, le nom générique d'opération et le statut restent publics.
enum APILog {
    static let logger = Logger(subsystem: "app.kphotos", category: "api")

    static func request(method: String, url: URL, body _: Any?) {
        let operation = ["thumbnail", "preview", "download", "files", "init", "chunk"].contains(url.lastPathComponent)
            ? url.lastPathComponent : "metadata"
        logger.info("→ \(method, privacy: .public) \(operation, privacy: .public)")
    }

    static func response(url _: URL, statusCode: Int?, body _: Data?) {
        logger.info("← \(statusCode ?? 0, privacy: .public)")
    }
}

public protocol PhotoApiFetching: AnyObject {
    func listFolder(driveId: Int, folderId: String, cursor: String?, limit: Int) async throws -> FilePage
    func upload(
        driveId: Int,
        folderId: String,
        fileURL: URL,
        fileName: String,
        createdAt: Date,
        mimeType: String,
        clientToken: String
    ) async throws -> RemoteFileDTO
    func createDirectory(driveId: Int, name: String, parentId: String) async throws -> RemoteDirectoryDTO
    func listDrives() async throws -> [RemoteDriveDTO]

    // MARK: - Catégories (= albums kPhotos)

    func listCategories(driveId: Int) async throws -> [RemoteCategoryDTO]
    func createCategory(driveId: Int, name: String, color: String?) async throws -> RemoteCategoryDTO
    func updateCategory(driveId: Int, categoryId: Int, name: String?, color: String?) async throws -> RemoteCategoryDTO
    func deleteCategory(driveId: Int, categoryId: Int) async throws
    func addCategoryToFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws
    func removeCategoryFromFiles(driveId: Int, categoryId: Int, fileIds: [Int]) async throws
    func listCategoryFiles(driveId: Int, categoryId: Int, cursor: String?, limit: Int) async throws -> FilePage
    func thumbnailPackData(driveId: Int, reference: ThumbnailPackReference) async throws -> Data
    func thumbnailData(driveId: Int, fileId: String) async throws -> Data
    func thumbnailData(driveId: Int, fileId: String, revision: String, priority: Int) async throws -> Data
    func previewData(driveId: Int, fileId: String, width: Int?, height: Int?, quality: Int?) async throws -> Data
    func downloadFile(driveId: Int, fileId: String) async throws -> URL
    func originalMetadata(driveId: Int, fileId: String, isVideo: Bool) async throws -> EmbeddedMediaMetadata
    func saveMediaIndex(
        _ index: MediaLibraryIndex,
        name: String,
        previous: MediaIndexUploadState?,
        clientToken: String
    ) async throws -> MediaIndexUploadState
    func mediaIndex(driveId: Int, rootId: String) async throws -> (String, MediaLibraryIndex)?
    func playbackURL(driveId: Int, fileId: String) async throws -> URL
    func downloadURL(driveId: Int, fileId: String) -> URL
    func previewURL(driveId: Int, fileId: String) -> URL
    func deleteFile(driveId: Int, fileId: String) async throws
    func fileInfo(driveId: Int, fileId: String) async throws -> RemoteFileDetailDTO
}

public extension PhotoApiFetching {
    func thumbnailData(driveId: Int, fileId: String, revision: String, priority: Int) async throws -> Data {
        try await thumbnailData(driveId: driveId, fileId: fileId)
    }

    func saveMediaIndex(
        _ index: MediaLibraryIndex,
        name: String,
        previous: MediaIndexUploadState?,
        clientToken: String
    ) async throws -> MediaIndexUploadState {
        throw PhotoAPIError.invalidResponse
    }

    func thumbnailPackData(
        driveId: Int,
        reference: ThumbnailPackReference
    ) async throws -> Data { throw PhotoAPIError.invalidResponse }
    func mediaIndex(driveId: Int, rootId: String) async throws -> (String, MediaLibraryIndex)? { nil }
    func originalMetadata(driveId: Int, fileId: String, isVideo: Bool) async throws -> EmbeddedMediaMetadata {
        throw PhotoAPIError.invalidResponse
    }
}

public final class PhotoApiFetcher: PhotoApiFetching {
    static let maxRetries = 3
    static let baseBackoff: TimeInterval = 0.5

    let session: Session
    let binaryReadConfiguration: URLSessionConfiguration
    let decoder: JSONDecoder
    private let requestBudget: APIRequestBudget?

    public init(interceptor: RequestInterceptor? = nil, decoder: JSONDecoder = .kPhotos) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        self.binaryReadConfiguration = .ephemeral
        self.session = Session(configuration: configuration, interceptor: interceptor)
        self.decoder = decoder
        self.requestBudget = .shared
    }

    // Inject a local URLProtocol in transport tests without real credentials or network.
    init(configuration: URLSessionConfiguration) {
        self.binaryReadConfiguration = configuration
        self.session = Session(configuration: configuration)
        self.decoder = .kPhotos
        self.requestBudget = nil
    }

    public func previewURL(driveId: Int, fileId: String) -> URL {
        Endpoint.preview(driveId: driveId, fileId: fileId).url
    }

    public func downloadURL(driveId: Int, fileId: String) -> URL {
        Endpoint.download(driveId: driveId, fileId: fileId).url
    }
}

public extension JSONDecoder {
    static let kPhotos: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}

// MARK: - Retry helper

extension PhotoApiFetcher {
    func waitForRequest(priority: Int = 0) async throws {
        try Task.checkCancellation()
        try await requestBudget?.wait(priority: priority)
    }

    func performWithRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0 ..< Self.maxRetries {
            do {
                try Task.checkCancellation()
                return try await operation()
            } catch {
                try Task.checkCancellation()
                lastError = error
                guard Self.isRetryable(error) else { throw error }
                let delay = Self.baseBackoff * pow(2.0, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? PhotoAPIError.network(underlying: "unknown")
    }

    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case PhotoAPIError.network,
             PhotoAPIError.rateLimited,
             PhotoAPIError.server(statusCode: 500 ..< 600, _):
            true
        default:
            false
        }
    }

    static func mapAFError(
        _ error: AFError,
        statusCode: Int? = nil,
        url: URL? = nil,
        body: Data? = nil
    ) -> PhotoAPIError {
        if let url { APILog.response(url: url, statusCode: statusCode, body: body) }
        let suffix = ""

        if let code = statusCode {
            let message = [error.errorDescription, suffix.isEmpty ? nil : suffix]
                .compactMap { $0 }.joined(separator: " — ")
            switch code {
            case 401, 403: return .unauthorized
            case 404: return .notFound
            case 429: return .rateLimited(retryAfter: nil)
            case 500 ..< 600: return .server(statusCode: code, message: message)
            default: return .server(statusCode: code, message: message)
            }
        }

        // Pas de HTTP response : adapter / DNS / ATS / timeout. On expose AFError + URL.
        let reason = [
            "\(error)",
            suffix.isEmpty ? nil : suffix
        ].compactMap { $0 }.joined(separator: " — ")
        return .network(underlying: reason)
    }
}
