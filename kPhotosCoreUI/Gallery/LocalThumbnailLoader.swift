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

import Photos
import SwiftUI
import UIKit

/// Chargeur de thumbnail local à partir d'un `PHAsset.localIdentifier`.
/// Utilise `PHCachingImageManager` partagé — la fenêtre de cache est gérée par
/// `LocalThumbnailCacheController` ci-dessous depuis la vue parente.
@MainActor
public final class LocalThumbnailLoader: ObservableObject {
    @Published public private(set) var image: UIImage?

    private let localIdentifier: String
    private let targetSize: CGSize
    private var requestID: PHImageRequestID?

    public init(localIdentifier: String, targetSize: CGSize) {
        self.localIdentifier = localIdentifier
        self.targetSize = targetSize
    }

    deinit {
        if let requestID {
            LocalThumbnailCacheController.sharedManager.cancelImageRequest(requestID)
        }
    }

    public func load() {
        guard image == nil else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true // iCloud Photo Library : on garde local-only.
        options.resizeMode = .fast

        requestID = LocalThumbnailCacheController.sharedManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] result, info in
            guard let self else { return }
            // `opportunistic` peut callback plusieurs fois (low-res puis hi-res).
            // On accepte chaque résultat non-`isDegraded` final, et on prend le low-res
            // comme placeholder immédiat.
            if let result {
                image = result
            }
            // Quand la dernière image arrive, on libère le requestID.
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded {
                requestID = nil
            }
        }
    }
}

/// Pilotage du cache de thumbnails — à appeler depuis la liste pour pré-charger
/// la fenêtre visible et libérer celle qui sort de l'écran.
/// Wrapper léger autour de `PHCachingImageManager.startCachingImages`.
public enum LocalThumbnailCacheController {
    /// Instance partagée — `PHCachingImageManager.default()` est hérité de `PHImageManager`
    /// et retourne le type parent, donc on instancie directement.
    static let sharedManager = PHCachingImageManager()

    public static func startCaching(localIdentifiers: [String], targetSize: CGSize) {
        guard !localIdentifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var collected: [PHAsset] = []
        collected.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in collected.append(asset) }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        sharedManager.startCachingImages(
            for: collected,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    public static func stopCaching(localIdentifiers: [String], targetSize: CGSize) {
        guard !localIdentifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var collected: [PHAsset] = []
        collected.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in collected.append(asset) }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        sharedManager.stopCachingImages(
            for: collected,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    public static func stopAll() {
        sharedManager.stopCachingImagesForAllAssets()
    }
}
