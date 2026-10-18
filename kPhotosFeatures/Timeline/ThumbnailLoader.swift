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
import kPhotosCore
import UIKit

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private let driveId: Int
    private let fileId: String

    @InjectService private var api: PhotoApiFetching

    init(driveId: Int, fileId: String) {
        self.driveId = driveId
        self.fileId = fileId
    }

    /// Ordre des sources : RAM → disque → API thumbnail → API preview (fallback).
    /// La sauvegarde sur disque évite de retaper l'API à chaque relance de l'app
    /// (cf. AGENTS.md §17 et le rate limit de 60 req/min).
    ///
    /// Fallback preview : certains fichiers n'ont pas (ou pas encore) de thumbnail
    /// généré côté kDrive — l'endpoint dédié renvoie alors une erreur ou un corps
    /// non-image. Le endpoint preview, lui, répond toujours. Sans ce fallback la
    /// tuile restait blanche à vie (`UIImage(data:)` nil silencieux).
    func load() async {
        if image != nil || isLoading { return }
        let cacheKey = "\(driveId)-\(fileId)"

        if let cached = ThumbnailCache.shared.image(forKey: cacheKey) {
            image = cached
            return
        }

        if let disk = ThumbnailCache.shared.diskImage(forKey: cacheKey) {
            ThumbnailCache.shared.store(disk, forKey: cacheKey)
            image = disk
            return
        }

        isLoading = true
        defer { isLoading = false }

        // 1. Thumbnail dédié — rapide et léger.
        if let data = try? await api.thumbnailData(driveId: driveId, fileId: fileId),
           let uiImage = UIImage(data: data) {
            ThumbnailCache.shared.store(uiImage, forKey: cacheKey)
            ThumbnailCache.shared.storeOnDisk(data, forKey: cacheKey)
            image = uiImage
            return
        }

        // 2. Fallback : preview redimensionné. Plus lourd mais toujours disponible.
        if let data = try? await api.previewData(
            driveId: driveId, fileId: fileId,
            width: 400, height: 400, quality: 80
        ), let uiImage = UIImage(data: data) {
            ThumbnailCache.shared.store(uiImage, forKey: cacheKey)
            ThumbnailCache.shared.storeOnDisk(data, forKey: cacheKey)
            image = uiImage
        }
    }
}

/// Cache deux niveaux : RAM (NSCache, eviction OS) + disque (Caches/, plafonné à
/// ~100 MB). Le disque ne purge pas lui-même — on s'appuie sur le fait qu'iOS
/// vide `Caches/` sous pression de stockage.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let memory = NSCache<NSString, UIImage>()
    private let diskDirectory: URL?

    private init() {
        memory.countLimit = 600

        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("kPhotosThumbnails", isDirectory: true)
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
        memory.setObject(image, forKey: key as NSString)
    }

    func diskImage(forKey key: String) -> UIImage? {
        guard let url = diskURL(for: key),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    func storeOnDisk(_ data: Data, forKey key: String) {
        guard let url = diskURL(for: key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func diskData(forKey key: String) -> Data? {
        guard let url = diskURL(for: key) else { return nil }
        return try? Data(contentsOf: url)
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
/// petite (40 items max en RAM, NSCache pour eviction OS) et un dossier disque
/// dédié pour éviter de réinterroger l'API au re-tap.
final class PreviewCache {
    static let shared = PreviewCache()
    private let memory = NSCache<NSString, UIImage>()
    private let diskDirectory: URL?

    private init() {
        memory.countLimit = 40

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
        memory.setObject(image, forKey: key as NSString)
    }

    func diskImage(forKey key: String) -> UIImage? {
        guard let url = diskURL(for: key),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    func storeOnDisk(_ data: Data, forKey key: String) {
        guard let url = diskURL(for: key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func diskData(forKey key: String) -> Data? {
        guard let url = diskURL(for: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func diskURL(for key: String) -> URL? {
        guard let dir = diskDirectory else { return nil }
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).jpg")
    }
}
