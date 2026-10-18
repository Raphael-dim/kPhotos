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
import ImageIO
import kPhotosCore
import UIKit

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private static var failedUntil: [String: Date] = [:]
    private let driveId: Int
    private let fileId: String

    private var pack: ThumbnailPackReference?
    private var revision: String
    @InjectService private var packs: ThumbnailPackFetching
    @InjectService private var api: PhotoApiFetching
    @InjectService private var thumbnails: CloudThumbnailFetching

    init(driveId: Int, fileId: String, pack: ThumbnailPackReference? = nil, revision: String = "") {
        self.pack = pack; self.revision = revision
        self.driveId = driveId
        self.fileId = fileId
    }

    /// Ordre des sources : RAM → disque → API thumbnail → API preview (fallback).
    /// La sauvegarde sur disque évite de retaper l'API à chaque relance de l'app
    /// (cf. AGENTS.md §17 et le rate limit de 60 req/min).
    ///
    /// Fallback preview : certains fichiers n'ont pas (ou pas encore) de thumbnail
    /// généré côté kDrive — l'endpoint dédié renvoie alors une erreur ou un corps
    /// non-image. Le preview peut également être indisponible. Sans ce fallback la
    /// tuile restait blanche à vie (`UIImage(data:)` nil silencieux).
    func configure(pack: ThumbnailPackReference?, revision: String) {
        if self.revision != revision { image = nil }
        self.pack = pack; self.revision = revision
    }

    static func cacheKey(driveId: Int, fileId: String, revision: String) -> String {
        let legacy = "\(driveId)-\(fileId)"
        guard !revision.isEmpty else { return legacy }
        let digest = SHA256.hash(data: Data(revision.utf8)).map { String(format: "%02x", $0) }.joined()
        return legacy + "-" + digest
    }

    static func mapImage(for photo: PhotoSnapshot) async -> UIImage? {
        let loader = ThumbnailLoader(
            driveId: photo.driveId,
            fileId: photo.fileId,
            pack: photo.thumbnailPack,
            revision: photo.remoteRevision
        )
        await loader.load()
        return loader.image
    }

    func releaseImage() { image = nil }

    func load(priority: Int = 2) async {
        // SwiftUI may restart a cell task before the previous canceled task has
        // unwound. Wait for its cleanup rather than permanently skipping the reload.
        while isLoading {
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
        }
        if image != nil || Task.isCancelled { return }
        let cacheKey = Self.cacheKey(driveId: driveId, fileId: fileId, revision: revision)

        if let cached = ThumbnailCache.shared.image(forKey: cacheKey) {
            image = cached
            return
        }

        isLoading = true
        defer { isLoading = false }
        if await loadDiskImage(cacheKey: cacheKey) { return }

        if let until = Self.failedUntil[cacheKey], until > Date() { return }
        // Scrolling past an uncached tile must not consume a scarce API request.
        do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
        guard !Task.isCancelled else { return }

        if await loadPackedImage(cacheKey: cacheKey) { return }
        guard !Task.isCancelled else { return }

        if await loadSavedPreview(cacheKey: cacheKey) { return }
        guard !Task.isCancelled else { return }
        await loadRemoteImage(cacheKey: cacheKey, priority: priority)
    }

    private func loadDiskImage(cacheKey: String) async -> Bool {
        if let disk = await ThumbnailCache.shared.diskImageAsync(forKey: cacheKey) {
            ThumbnailCache.shared.store(disk, forKey: cacheKey)
            if !Task.isCancelled { image = disk }
            return true
        }

        return false
    }

    private func loadSavedPreview(cacheKey: String) async -> Bool {
        // Reuse a previously opened original when the server has no generated preview.
        var savedPreview = PreviewCache.shared.image(forKey: cacheKey)
        if savedPreview == nil { savedPreview = await PreviewCache.shared.diskImageAsync(forKey: cacheKey) }
        guard !Task.isCancelled else { return false }
        if let preview = savedPreview {
            await cache(preview, key: cacheKey)
            return true
        }
        return false
    }

    private func loadRemoteImage(cacheKey: String, priority: Int) async {
        do {
            do {
                let data = try await thumbnails.data(driveId: driveId, fileId: fileId, revision: revision, priority: priority)
                guard let decoded = await ThumbnailImageDecoder.decode(data) else { throw PhotoAPIError.invalidResponse }
                await cache(decoded, key: cacheKey)
                return
            } catch {
                guard Self.canTryOriginal(after: error), !Task.isCancelled else { throw error }
            }
            do {
                let data = try await api.previewData(driveId: driveId, fileId: fileId, width: 400, height: 400, quality: 80)
                guard let decoded = await ThumbnailImageDecoder.decode(data) else { throw PhotoAPIError.invalidResponse }
                await cache(decoded, key: cacheKey)
                return
            } catch {
                guard Self.canTryOriginal(after: error), !Task.isCancelled else { throw error }
            }
            try await downloadAndCacheOriginalImage(cacheKey: cacheKey)
        } catch {
            // The neutral placeholder remains retryable. Do not hammer missing/unsupported previews.
            if Self.canTryOriginal(after: error), !Task.isCancelled {
                Self.failedUntil[cacheKey] = Date().addingTimeInterval(60)
            }
        }
        if Self.failedUntil.count > 1000 { Self.failedUntil = Self.failedUntil.filter { $0.value > Date() } }
    }

    private func loadPackedImage(cacheKey: String) async -> Bool {
        if let pack {
            do {
                if let bytes = try await packs.imageData(driveId: driveId, reference: pack, fileId: fileId, revision: revision),
                   let decoded = await ThumbnailImageDecoder.decode(bytes) {
                    ThumbnailCache.shared.store(decoded, forKey: cacheKey)
                    if !Task.isCancelled { image = decoded }
                    return true
                }
            } catch {
                if Task.isCancelled { return false }
                // A missing/corrupt derivative cache must not prevent the ordinary server thumbnail fallback.
            }
        }

        return false
    }

    private func downloadAndCacheOriginalImage(cacheKey: String) async throws {
        // Never download a large video or RAW just to draw a gallery tile.
        let info = try await api.fileInfo(driveId: driveId, fileId: fileId)
        let isImageName = ["heic", "heif", "jpg", "jpeg", "png", "webp", "tif", "tiff"]
            .contains((info.name as NSString).pathExtension.lowercased())
        guard info.mimeType.hasPrefix("image/") ||
            ((info.mimeType.isEmpty || info.mimeType == "application/octet-stream") && isImageName),
            info.size > 0, info.size <= 20_000_000 else {
            throw PhotoAPIError.invalidResponse
        }
        let url = try await api.downloadFile(driveId: driveId, fileId: fileId)
        defer { try? FileManager.default.removeItem(at: url) } // Owned temporary download only.
        let decoded = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = ThumbnailImageDecoder.image(source: source) else { return UIImage?.none }
            return UIImage(cgImage: cg)
        }.value
        guard let decoded else { throw PhotoAPIError.invalidResponse }
        await cache(decoded, key: cacheKey)
    }

    static func canTryOriginal(after error: Error) -> Bool {
        switch error {
        case PhotoAPIError.notFound, PhotoAPIError.invalidResponse: true
        case PhotoAPIError.server(let code, _): [400, 415, 422].contains(code)
        default: false
        }
    }

    private func cache(_ decoded: UIImage, key: String) async {
        let compressed = await Task.detached(priority: .utility) { () -> (UIImage, Data?) in
            if let cg = decoded.cgImage, max(cg.width, cg.height) <= 400 {
                return (decoded, decoded.jpegData(compressionQuality: 0.75))
            }
            let data = decoded.jpegData(compressionQuality: 0.85)
            let small = data.flatMap { ThumbnailImageDecoder.decodeSynchronously($0) } ?? decoded
            return (small, small.jpegData(compressionQuality: 0.75))
        }.value
        ThumbnailCache.shared.store(compressed.0, forKey: key)
        if let data = compressed.1 { ThumbnailCache.shared.storeOnDisk(data, forKey: key) }
        Self.failedUntil[key] = nil
        if !Task.isCancelled { image = compressed.0 }
    }
}

/// Cache deux niveaux : RAM (NSCache, eviction OS) + disque (Caches/, plafonné à
/// 512 MiB maximum). Disk decoding, writes and periodic eviction run off the UI thread.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let memory = NSCache<NSString, UIImage>()
    private let diskDirectory: URL?

    init(directory: URL? = nil) {
        memory.countLimit = 1000
        memory.totalCostLimit = 96 * 1024 * 1024

        let fm = FileManager.default
        if let caches = directory ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = directory ?? caches.appendingPathComponent("kPhotosThumbnails", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.diskDirectory = dir
        } else {
            self.diskDirectory = nil
        }
    }

    func image(forKey key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        memory.setObject(
            image,
            forKey: key as NSString,
            cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        )
    }

    func diskImage(forKey key: String) -> UIImage? {
        guard let url = diskURL(for: key),
              let data = try? Data(contentsOf: url),
              let image = ThumbnailImageDecoder.decodeSynchronously(data) else { return nil }
        ImageDiskBudget.touch(url)
        return image
    }

    func diskImageAsync(forKey key: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { self.diskImage(forKey: key) }.value
    }

    func storeOnDisk(_ data: Data, forKey key: String) {
        guard let url = diskURL(for: key) else { return }
        ImageDiskBudget.store(data, at: url, limit: 512 * 1024 * 1024)
    }

    private func diskURL(for key: String) -> URL? {
        guard let dir = diskDirectory else { return nil }
        // Sanitize : le `key` est composé de chiffres + dash, mais on reste prudent.
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).jpg")
    }
}

/// Cache dédié aux previews HD du viewer plein écran. Strictement séparé du
/// `ThumbnailCache` car chaque entrée pèse ~25 MB décodée — on garde une fenêtre
/// petite (12 items max en RAM, NSCache pour eviction OS) et un dossier disque
/// dédié pour éviter de réinterroger l'API au re-tap.
final class PreviewCache {
    static let shared = PreviewCache()
    private let memory = NSCache<NSString, UIImage>()
    private let diskDirectory: URL?

    private init() {
        memory.countLimit = 12
        memory.totalCostLimit = 96 * 1024 * 1024

        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("kPhotosPreviews", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.diskDirectory = dir
        } else {
            self.diskDirectory = nil
        }
    }

    func image(forKey key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        memory.setObject(
            image,
            forKey: key as NSString,
            cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        )
    }

    func diskImage(forKey key: String) -> UIImage? {
        guard let url = diskURL(for: key),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    func diskImageAsync(forKey key: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { self.diskImage(forKey: key) }.value
    }

    func storeOnDisk(_ data: Data, forKey key: String) {
        guard let url = diskURL(for: key) else { return }
        ImageDiskBudget.store(data, at: url, limit: 256 * 1024 * 1024)
    }

    private func diskURL(for key: String) -> URL? {
        guard let dir = diskDirectory else { return nil }
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).jpg")
    }
}

enum ThumbnailImageDecoder {
    static func image(source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func decodeSynchronously(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = image(source: source) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { decodeSynchronously(data) }.value
    }
}

/// Only app-owned disposable cache files enter this queue. Never enumerate or remove originals.
