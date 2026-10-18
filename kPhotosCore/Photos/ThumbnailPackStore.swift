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

import CryptoKit
import Foundation

public protocol ThumbnailPackFetching: AnyObject {
    func imageData(driveId: Int, reference: ThumbnailPackReference, fileId: String, revision: String) async throws -> Data?
}

/// One bounded download can supply a whole group of thumbnails; concurrent tiles share it.
public actor ThumbnailPackStore: ThumbnailPackFetching {
    private let api: PhotoApiFetching
    private let directory: URL
    private var inflight: [String: Task<URL, Error>] = [:]
    private var validated: [String: Date] = [:]
    private var accessed: [String: Date] = [:]
    public init(api: PhotoApiFetching, directory: URL? = nil) {
        self.api = api
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kPhotosThumbnails", isDirectory: true)
    }

    public func imageData(
        driveId: Int,
        reference: ThumbnailPackReference,
        fileId: String,
        revision: String
    ) async throws -> Data? {
        guard reference.sha256.count == 64, reference.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw PhotoAPIError.invalidResponse
        }
        let key = "pack-\(driveId)-\(reference.sha256)"
        let url = directory.appendingPathComponent(key + ".sqlite")
        var usable = false
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024,
           let modified = attrs[.modificationDate] as? Date {
            if validated[key] == modified {
                usable = true
            } else if let bytes = try? Data(contentsOf: url) {
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                if digest == reference.sha256 { validated[key] = modified; usable = true }
            }
        }
        if !usable {
            let task: Task<URL, Error>
            if let pending = inflight[key] { task = pending } else {
                task = Task {
                    let bytes = try await api.thumbnailPackData(driveId: driveId, reference: reference)
                    guard bytes.count <= 16 * 1024 * 1024,
                          SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == reference.sha256 else {
                        throw PhotoAPIError.invalidResponse
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let free = try (
                        FileManager.default
                            .attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
                    )?.int64Value ?? 0
                    guard free - Int64(bytes.count) > 128 * 1024 * 1024 else {
                        throw PhotoAPIError.invalidResponse
                    }
                    try bytes.write(to: url, options: .atomic)
                    ImageDiskBudget.scheduleTrim(directory: directory, limit: 512 * 1024 * 1024)
                    return url
                }
                inflight[key] = task
            }
            do { _ = try await task.value; inflight[key] = nil } catch { inflight[key] = nil; throw error }
        }
        try Task.checkCancellation()
        let bytes = try ThumbnailPack.imageData(at: url, fileId: fileId, revision: revision)
        if Date().timeIntervalSince(accessed[key] ?? .distantPast) > 60 {
            accessed[key] = Date(); ImageDiskBudget.touch(url)
        }
        return bytes
    }
}
