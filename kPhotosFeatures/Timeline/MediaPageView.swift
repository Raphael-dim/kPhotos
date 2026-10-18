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

import AVFoundation
import ImageIO
import kPhotosCore
import kPhotosResources
import Photos
import SwiftUI
import UIKit

// MARK: - MediaPageView

struct MediaPageView: View {
    /// Reserve space for native controls without shrinking the video itself.
    private static let appTopBarHeight: CGFloat = 68
    private static let appBottomBarHeight: CGFloat = 60
    private static let videoControlsGap: CGFloat = 16

    let media: ViewerMedia
    /// `true` quand cette page est la page courante du pager. Pilote la
    /// lecture vidéo : on démarre à l'ouverture de la page et on met en pause
    /// dès qu'on swipe vers un autre média (évite l'audio d'une vidéo hors-écran).
    let isActive: Bool
    /// Safe area de l'écran, propagée depuis le `GeometryReader` racine (le
    /// pager l'ignore, elle n'est donc pas lisible localement).
    let safeArea: EdgeInsets
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void

    @StateObject private var loader: MediaPageLoader
    @State private var isShowingLiveMotion = false
    @State private var liveMotionFailed = false

    init(
        media: ViewerMedia,
        isActive: Bool,
        safeArea: EdgeInsets,
        onSingleTap: @escaping () -> Void,
        onZoomChange: @escaping (Bool) -> Void
    ) {
        self.media = media
        self.isActive = isActive
        self.safeArea = safeArea
        self.onSingleTap = onSingleTap
        self.onZoomChange = onZoomChange
        _loader = StateObject(wrappedValue: MediaPageLoader(media: media))
    }

    private var videoControlsInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: Self.appTopBarHeight + Self.videoControlsGap,
            left: 0,
            bottom: Self.appBottomBarHeight + Self.videoControlsGap,
            right: 0
        )
    }

    var body: some View {
        ZStack {
            Color.black

            if media.isVideo, let poster = loader.image {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
            }

            if isShowingLiveMotion, let player = loader.livePlayer {
                NeutralVideoPlayer(player: player, controlsInsets: videoControlsInsets)
                    .onAppear { if isActive { player.play() } }
                    .onChange(of: isActive) { active in
                        if active { player.play() } else { player.pause() }
                    }
            } else if let image = loader.image, !media.isVideo {
                ZoomableScrollView(
                    image: image,
                    onSingleTap: onSingleTap,
                    onZoomChange: onZoomChange
                )
            } else if let player = loader.player {
                // The image uses the full screen; only playback controls avoid the app bars.
                NeutralVideoPlayer(player: player, controlsInsets: videoControlsInsets)
                    .onAppear { if isActive { player.play() } }
                    .onChange(of: isActive) { active in
                        if active { player.play() } else { player.pause() }
                    }
            } else if loader.isLoadingPreview {
                ProgressView().tint(.white)
            } else if let error = loader.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button(L10n.Common.retry) {
                        Task { await loader.load() }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if loader.hasLiveMotion {
                Button {
                    if isShowingLiveMotion {
                        loader.pauseLiveMotion()
                        isShowingLiveMotion = false
                    } else {
                        Task {
                            if await loader.loadLiveMotion() {
                                isShowingLiveMotion = true
                            } else {
                                liveMotionFailed = true
                            }
                        }
                    }
                } label: {
                    Label(
                        isShowingLiveMotion ? L10n.Viewer.liveStill : L10n.Viewer.liveMotion,
                        systemImage: isShowingLiveMotion ? "photo" : "livephoto.play"
                    )
                    .font(.footnote.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.trailing, 20)
                .padding(.bottom, safeArea.bottom + Self.appBottomBarHeight + 20)
            }
        }
        .alert(L10n.Viewer.liveMotionUnavailable, isPresented: $liveMotionFailed) {
            Button(L10n.Common.done, role: .cancel) {}
        }
        .task { await loader.load() }
        .onDisappear { loader.stopStreaming() }
    }
}

// MARK: - MediaPageLoader

/// Chargement en deux phases :
/// 1. Au `init`, on remplit `image` immédiatement avec la vignette déjà en cache
///    (issue du défilement de la galerie) — évite tout flash de loader.
/// 2. Au `load()`, on délègue à la stratégie correspondant à la source :
///    - `.cloud` : preview HD kDrive (cache disque, puis API width=2500/height=1500/quality=80).
///    - `.local` : `PHImageManager` (taille max, accès iCloud Photo Library autorisé).
///
/// Chaque branche reste autonome ; la classe sert d'aiguillage et factorise l'état
/// publié (`image`, `player`, `isLoadingPreview`, `errorMessage`).
@MainActor
private final class MediaPageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var livePlayer: AVPlayer?
    @Published private(set) var hasLiveMotion = false
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var errorMessage: String?

    private let media: ViewerMedia
    private var didLoadPreview = false
    private var remoteVideo: RemoteMediaAsset?
    private var remoteLiveVideo: RemoteMediaAsset?
    private var localLiveURL: URL?

    @InjectService private var api: PhotoApiFetching

    /// Dimensions ciblées pour le preview HD. Cf. valeurs utilisées par l'app
    /// officielle iOS kDrive — bon compromis qualité / poids réseau.
    private let previewWidth = 2500
    private let previewHeight = 1500
    private let previewQuality = 80

    init(media: ViewerMedia) {
        self.media = media
        prefillFromCache()
    }

    func load() async {
        switch media {
        case .cloud(let snapshot):
            await loadCloud(snapshot)
        case .local(let asset):
            await loadLocal(asset)
        }
    }

    func stopStreaming() {
        player?.pause()
        livePlayer?.pause()
        player = nil
        livePlayer = nil
        remoteVideo?.cancel()
        remoteVideo = nil
        remoteLiveVideo?.cancel()
        remoteLiveVideo = nil
        if let localLiveURL { try? FileManager.default.removeItem(at: localLiveURL) }
        localLiveURL = nil
    }

    func pauseLiveMotion() { livePlayer?.pause() }

    func loadLiveMotion() async -> Bool {
        if livePlayer != nil { return true }
        do {
            switch media {
            case .cloud(let photo):
                guard let motionId = photo.liveMotionFileId else { return false }
                let url = try await api.playbackURL(driveId: photo.driveId, fileId: motionId)
                let source = try RemoteMediaAsset(url: url, maximumBytes: nil)
                guard try await source.asset.load(.isPlayable) else { throw PhotoAPIError.invalidResponse }
                try Task.checkCancellation()
                remoteLiveVideo = source
                livePlayer = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
            case .local(let asset):
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
                guard let phAsset = fetch.firstObject,
                      let resource = PHAssetResource.assetResources(for: phAsset).first(where: { $0.type == .pairedVideo }) else { return false }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    try Task.checkCancellation()
                    localLiveURL = url
                    livePlayer = AVPlayer(url: url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }
            return livePlayer != nil
        } catch {
            return false
        }
    }

    // MARK: Pré-remplissage

    /// Pré-remplissage cloud uniquement : pour le local, la vignette PhotoKit est
    /// gérée par `LocalThumbnailLoader` (cache `PHCachingImageManager`) et n'est
    /// pas accessible via une simple lookup synchrone — on accepte un bref
    /// `ProgressView` au premier ouvrage.
    private func prefillFromCache() {
        guard case .cloud(let photo) = media else { return }
        let key = ThumbnailLoader.cacheKey(driveId: photo.driveId, fileId: photo.fileId, revision: photo.remoteRevision)
        if let cached = ThumbnailCache.shared.image(forKey: key) {
            image = cached
        }
        if let highRes = PreviewCache.shared.image(forKey: key) {
            image = highRes
            didLoadPreview = true
        }
    }

    // MARK: Cloud

    private func loadCloud(_ photo: PhotoSnapshot) async {
        hasLiveMotion = photo.liveMotionFileId != nil
        if !photo.localIdentifier.isEmpty,
           let local = PHAsset.fetchAssets(withLocalIdentifiers: [photo.localIdentifier], options: nil).firstObject {
            if photo.isVideo, let item = await Self.requestPlayerItem(for: local) {
                player = AVPlayer(playerItem: item); errorMessage = nil; return
            }
            if !photo.isVideo, let original = await Self.requestImage(for: local) {
                image = original; didLoadPreview = true; errorMessage = nil; return
            }
        }
        if photo.isVideo {
            if player != nil { return }
            do {
                isLoadingPreview = true
                defer { isLoadingPreview = false }
                let url = try await api.playbackURL(driveId: photo.driveId, fileId: photo.fileId)
                let source = try RemoteMediaAsset(url: url, maximumBytes: nil)
                remoteVideo = source
                guard try await source.asset.load(.isPlayable) else { throw PhotoAPIError.invalidResponse }
                try Task.checkCancellation()
                player = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
                errorMessage = nil
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                errorMessage = error.localizedDescription
            }
            return
        }

        if didLoadPreview { return }
        let key = ThumbnailLoader.cacheKey(driveId: photo.driveId, fileId: photo.fileId, revision: photo.remoteRevision)

        if let disk = await PreviewCache.shared.diskImageAsync(forKey: key) {
            PreviewCache.shared.store(disk, forKey: key)
            image = disk
            didLoadPreview = true
            return
        }

        isLoadingPreview = true
        defer { isLoadingPreview = false }
        do {
            let data = try await api.previewData(
                driveId: photo.driveId,
                fileId: photo.fileId,
                width: previewWidth,
                height: previewHeight,
                quality: previewQuality
            )
            guard let highRes = UIImage(data: data) else { throw PhotoAPIError.invalidResponse }
            PreviewCache.shared.store(highRes, forKey: key)
            PreviewCache.shared.storeOnDisk(data, forKey: key)
            image = highRes
            didLoadPreview = true
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            guard ThumbnailLoader.canTryOriginal(after: error) else {
                errorMessage = error.localizedDescription
                return
            }
            // A preview 404 is not evidence that the original was deleted.
            do {
                let url = try await api.downloadFile(driveId: photo.driveId, fileId: photo.fileId)
                defer { try? FileManager.default.removeItem(at: url) }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 3000
                      ] as CFDictionary) else { throw PhotoAPIError.invalidResponse }
                let original = UIImage(cgImage: decoded)
                image = original
                didLoadPreview = true
                PreviewCache.shared.store(original, forKey: key)
                if let jpeg = original.jpegData(compressionQuality: 0.9) {
                    PreviewCache.shared.storeOnDisk(jpeg, forKey: key)
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Local (PhotoKit)

    private func loadLocal(_ asset: LocalAssetSnapshot) async {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
        guard let phAsset = fetch.firstObject else {
            // Asset disparu de la photothèque entre l'index et l'ouverture du viewer.
            if image == nil { errorMessage = L10n.Common.errorGeneric }
            return
        }
        hasLiveMotion = phAsset.mediaSubtypes.contains(.photoLive)

        if asset.isVideo {
            if player != nil { return }
            if let item = await Self.requestPlayerItem(for: phAsset) {
                player = AVPlayer(playerItem: item)
                errorMessage = nil
            } else if player == nil {
                errorMessage = L10n.Common.errorGeneric
            }
            return
        }

        if didLoadPreview { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        if let result = await Self.requestImage(for: phAsset) {
            image = result
            didLoadPreview = true
            errorMessage = nil
        } else if image == nil {
            errorMessage = L10n.Common.errorGeneric
        }
    }

    /// Récupère une image plein-cadre depuis PhotoKit. `PHImageManagerMaximumSize`
    /// renvoie l'asset à sa taille native — le `ZoomableScrollView` se chargera
    /// du fit à l'écran. `isNetworkAccessAllowed = true` couvre les assets stockés
    /// dans iCloud Photo Library (photo qui n'a pas encore retéléchargé localement).
    private nonisolated static func requestImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .none
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !didResume, !degraded else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    private nonisolated static func requestPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            var didResume = false
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: item)
            }
        }
    }
}
