/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

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

public struct ExportedAsset: Equatable {
    public let localIdentifier: String
    public let fileURL: URL
    public let fileName: String
    public let takenAt: Date
    public let mimeType: String
    public let isVideo: Bool
}

public protocol PHAssetExporting: AnyObject {
    /// Liste les prochains assets candidats à l'upload, triés par creationDate desc.
    /// Le `filter` permet de borner la requête PhotoKit en amont selon les réglages
    /// utilisateur (sinon un batch de N vidéos masquerait des photos plus récentes).
    func nextUploadCandidates(limit: Int, filter: SyncMediaFilter) async -> [PHAsset]
    func export(_ asset: PHAsset) async throws -> ExportedAsset
}

public extension PHAssetExporting {
    /// Compat backward — utilisée par les tests existants. Filtre par défaut : les deux.
    func nextUploadCandidates(limit: Int) async -> [PHAsset] {
        await nextUploadCandidates(limit: limit, filter: .both)
    }
}

public enum ExportError: Error, Equatable, LocalizedError {
    case noResource
    case writeFailed(String)
    case missingCreationDate

    /// Messages destinés à l'utilisateur (affichés au tap du badge d'échec).
    /// On reste factuel + actionnable : pas de jargon iOS, mais on mentionne iCloud
    /// quand c'est probablement la cause pour orienter le diagnostic.
    public var errorDescription: String? {
        switch self {
        case .noResource:
            return "Aucune ressource exploitable trouvée pour ce média (Live Photo incomplète, RAW non supporté, ou asset corrompu)."
        case .missingCreationDate:
            return "Date de prise de vue absente — ce média ne peut pas être indexé chronologiquement."
        case .writeFailed(let detail):
            return "Téléchargement de l'original depuis iCloud impossible. \(detail)"
        }
    }
}

public final class PHAssetExporterImpl: PHAssetExporting {
    private let fileManager: FileManager
    private let exportDirectory: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let tmp = fileManager.temporaryDirectory.appendingPathComponent("kPhotosExports", isDirectory: true)
        if !fileManager.fileExists(atPath: tmp.path) {
            try? fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
        }
        self.exportDirectory = tmp
    }

    public func nextUploadCandidates(limit: Int, filter: SyncMediaFilter) async -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.fetchLimit = limit
        options.predicate = Self.predicate(for: filter)

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    static func predicate(for filter: SyncMediaFilter) -> NSPredicate? {
        switch filter {
        case .photosOnly:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videosOnly:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .both:
            return NSPredicate(format: "mediaType == %d OR mediaType == %d",
                               PHAssetMediaType.image.rawValue,
                               PHAssetMediaType.video.rawValue)
        default:
            // OptionSet vide : on ne synchronise rien.
            return NSPredicate(value: false)
        }
    }

    public func export(_ asset: PHAsset) async throws -> ExportedAsset {
        guard let creationDate = asset.creationDate else {
            throw ExportError.missingCreationDate
        }

        // PHAssetResource = source brute du fichier (préserve EXIF, créé un nom déterministe).
        let resources = PHAssetResource.assetResources(for: asset)
        guard let primary = Self.primaryResource(in: resources) else {
            throw ExportError.noResource
        }

        let fileName = Self.makeFileName(
            creationDate: creationDate,
            localIdentifier: asset.localIdentifier,
            uniformTypeIdentifier: primary.uniformTypeIdentifier,
            originalFilename: primary.originalFilename
        )
        let destination = exportDirectory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }

        try await writeResource(primary, to: destination)

        return ExportedAsset(
            localIdentifier: asset.localIdentifier,
            fileURL: destination,
            fileName: fileName,
            takenAt: creationDate,
            mimeType: Self.mimeType(from: primary.uniformTypeIdentifier),
            isVideo: asset.mediaType == .video
        )
    }

    // MARK: - Helpers

    static func primaryResource(in resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
    }

    static func makeFileName(creationDate: Date,
                             localIdentifier: String,
                             uniformTypeIdentifier: String,
                             originalFilename: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let datePart = formatter.string(from: creationDate)
        let identifierPart = localIdentifier
            .replacingOccurrences(of: "/", with: "-")
            .components(separatedBy: "/").first ?? localIdentifier
        let ext = (originalFilename as NSString).pathExtension.lowercased()
        let finalExt = ext.isEmpty ? Self.fileExtension(from: uniformTypeIdentifier) : ext
        return "\(datePart)_\(identifierPart).\(finalExt)"
    }

    static func mimeType(from uti: String) -> String {
        switch uti {
        case "public.jpeg": return "image/jpeg"
        case "public.png": return "image/png"
        case "public.heic", "public.heif": return "image/heic"
        case "com.apple.quicktime-movie": return "video/quicktime"
        case "public.mpeg-4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    static func fileExtension(from uti: String) -> String {
        switch uti {
        case "public.jpeg": return "jpg"
        case "public.png": return "png"
        case "public.heic", "public.heif": return "heic"
        case "com.apple.quicktime-movie": return "mov"
        case "public.mpeg-4": return "mp4"
        default: return "dat"
        }
    }

    private func writeResource(_ resource: PHAssetResource, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: ExportError.writeFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
