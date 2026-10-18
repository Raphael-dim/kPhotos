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
import Photos

// MARK: - Protocol

public protocol MediaDownloading: AnyObject {
    func downloadAndImport(photos: [PhotoSnapshot], driveId: Int) async throws -> Int
}

// MARK: - Errors

public enum MediaDownloadError: LocalizedError {
    case photoLibraryAccessDenied
    case serverError(statusCode: Int)
    case importFailed

    public var errorDescription: String? {
        switch self {
        case .photoLibraryAccessDenied:
            return "L'accès à la Photothèque est requis. Activez-le dans Réglages > kPhotos."
        case .serverError(let code):
            return "Erreur serveur (\(code)) lors du téléchargement."
        case .importFailed:
            return "Impossible d'enregistrer le fichier dans la Photothèque."
        }
    }
}

// MARK: - Implementation

public final class MediaDownloadManager: MediaDownloading {
    private let api: PhotoApiFetching
    private let auth: AuthService
    private let fileManager: FileManager

    public init(api: PhotoApiFetching, auth: AuthService, fileManager: FileManager = .default) {
        self.api = api
        self.auth = auth
        self.fileManager = fileManager
    }

    // MARK: Public

    /// Télécharge et importe plusieurs photos dans la Photothèque iOS.
    /// - Lève une erreur si la permission est refusée (avant tout download).
    /// - Encaisse les échecs individuels en mode batch ; s'il n'y a qu'une seule
    ///   photo et qu'elle échoue, l'erreur est propagée à l'appelant.
    public func downloadAndImport(photos: [PhotoSnapshot], driveId: Int) async throws -> Int {
        try await requestPhotoLibraryAccessIfNeeded()

        var importedCount = 0
        var lastError: Error?

        for photo in photos {
            do {
                try await downloadAndSave(photo: photo)
                importedCount += 1
            } catch {
                lastError = error
            }
        }

        // Pour un téléchargement unitaire (viewer) : si rien n'a été importé on
        // propage l'erreur afin que l'UI puisse afficher un message précis.
        if importedCount == 0, let error = lastError {
            throw error
        }

        return importedCount
    }

    // MARK: Private – Auth

    private func requestPhotoLibraryAccessIfNeeded() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch current {
        case .authorized, .limited:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
            }
            guard status == .authorized || status == .limited else {
                throw MediaDownloadError.photoLibraryAccessDenied
            }
        default:
            throw MediaDownloadError.photoLibraryAccessDenied
        }
    }

    // MARK: Private – Download

    private func downloadAndSave(photo: PhotoSnapshot) async throws {
        let stillURL = try await downloadOriginal(
            driveId: photo.driveId,
            fileId: photo.fileId,
            name: photo.name,
            isVideo: photo.isVideo
        )
        defer { try? fileManager.removeItem(at: stillURL) }
        if let motionId = photo.liveMotionFileId, let motionName = photo.liveMotionName, !photo.isVideo {
            let motionURL = try await downloadOriginal(
                driveId: photo.driveId,
                fileId: motionId,
                name: motionName,
                isVideo: true
            )
            defer { try? fileManager.removeItem(at: motionURL) }
            let stillId = EmbeddedMediaMetadata.image(url: stillURL)?.livePhotoContentIdentifier
            let motionId = try await EmbeddedMediaMetadata.video(url: motionURL).livePhotoContentIdentifier
            guard let stillId, stillId == motionId, stillId == photo.liveContentIdentifier else {
                throw MediaDownloadError.importFailed
            }
            try await importToPhotoLibrary(fileURL: stillURL, mediaType: .image, pairedVideoURL: motionURL)
        } else {
            try await importToPhotoLibrary(fileURL: stillURL, mediaType: photo.isVideo ? .video : .image)
        }
    }

    private func downloadOriginal(driveId: Int, fileId: String, name: String, isVideo: Bool) async throws -> URL {
        let downloadURL = api.downloadURL(driveId: driveId, fileId: fileId)
        let token = try await auth.currentAccessToken()

        // Requête authentifiée.
        var request = URLRequest(url: downloadURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300

        // `URLSession.download` écrit directement sur disque → pas de pic mémoire,
        // essentiel pour les vidéos lourdes.
        let (tmpURL, response) = try await URLSession.shared.download(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            try? fileManager.removeItem(at: tmpURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MediaDownloadError.serverError(statusCode: code)
        }

        // Renomme le fichier temporaire avec l'extension correcte : PhotoKit en a
        // besoin pour reconnaître le type (JPEG, HEIC, MP4…).
        let ext = (name as NSString).pathExtension
        let destExt = ext.isEmpty ? (isVideo ? "mp4" : "jpg") : ext
        let destURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(destExt)

        try fileManager.moveItem(at: tmpURL, to: destURL)
        if !isVideo, let type = EmbeddedMediaMetadata.image(url: destURL)?.detectedImageType {
            let actualExtension: String? = switch type {
            case "public.jpeg": "jpg"
            case "public.heic": "heic"
            default: nil
            }
            if let actualExtension, actualExtension.caseInsensitiveCompare(destExt) != .orderedSame {
                let correctedURL = destURL.deletingPathExtension().appendingPathExtension(actualExtension)
                try fileManager.moveItem(at: destURL, to: correctedURL)
                return correctedURL
            }
        }
        return destURL
    }

    // MARK: Private – Import

    private func importToPhotoLibrary(
        fileURL: URL,
        mediaType: PHAssetMediaType,
        pairedVideoURL: URL? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                // PhotoKit déplace le fichier au lieu de le copier → économie disque.
                options.shouldMoveFile = true

                let req = PHAssetCreationRequest.forAsset()
                switch mediaType {
                case .image:
                    req.addResource(with: .photo, fileURL: fileURL, options: options)
                    if let pairedVideoURL {
                        req.addResource(with: .pairedVideo, fileURL: pairedVideoURL, options: options)
                    }
                case .video:
                    req.addResource(with: .video, fileURL: fileURL, options: options)
                default:
                    req.addResource(with: .photo, fileURL: fileURL, options: options)
                }
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? MediaDownloadError.importFailed)
                }
            })
        }
    }
}
