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
import UniformTypeIdentifiers

public struct ExportedResource: Equatable {
    public let fileURL: URL
    public let fileName: String
    public let mimeType: String
    public let resourceType: Int
    public let originalFilename: String
}

public struct ExportedAsset: Equatable {
    public let localIdentifier: String
    public let fileURL: URL
    public let fileName: String
    public let takenAt: Date
    public let mimeType: String
    public let isVideo: Bool
    public var additionalResources: [ExportedResource] = []
    public var metadata: Data?
    public var coordinate: MediaCoordinate?
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
            "Aucune ressource exploitable trouvée pour ce média (Live Photo incomplète, RAW non supporté, ou asset corrompu)."
        case .missingCreationDate:
            "Date de prise de vue absente — ce média ne peut pas être indexé chronologiquement."
        case .writeFailed(let detail):
            "Téléchargement de l'original depuis iCloud impossible. \(detail)"
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
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videosOnly:
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .both:
            NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        default:
            // OptionSet vide : on ne synchronise rien.
            NSPredicate(value: false)
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

        let baseName = Self.makeFileName(
            creationDate: creationDate,
            localIdentifier: asset.localIdentifier,
            uniformTypeIdentifier: primary.uniformTypeIdentifier,
            originalFilename: primary.originalFilename
        )
        let revision = asset.modificationDate.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "original"
        let fileName = (baseName as NSString).deletingPathExtension + "_v" + revision
            + "." + (baseName as NSString).pathExtension
        let directory = exportDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let destination = directory.appendingPathComponent(fileName)
            try await writeResource(primary, to: destination)
            let additional = try await exportCompanions(resources, primary: primary, fileName: fileName, directory: directory)
            let descriptors = Self.resourceDescriptors(primary: primary, fileName: fileName, additional: additional)
            // Fail closed if PhotoKit reports a Live Photo without its motion resource.
            if asset.mediaSubtypes.contains(.photoLive), !resources.contains(where: { $0.type == .pairedVideo }) {
                throw BackupSafetyError.incomplete
            }
            let metadata = Self.metadata(for: asset, createdAt: creationDate, descriptors: descriptors)
            var exported = ExportedAsset(
                localIdentifier: asset.localIdentifier,
                fileURL: destination,
                fileName: fileName,
                takenAt: creationDate,
                mimeType: Self.mimeType(from: primary.uniformTypeIdentifier),
                isVideo: asset.mediaType == .video
            )
            if let location = asset.location, location.horizontalAccuracy >= 0 {
                exported.coordinate = MediaCoordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            }
            exported.additionalResources = additional
            exported.metadata = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            return exported
        } catch {
            try? fileManager.removeItem(at: directory) // Only this export's temporary resources.
            throw error
        }
    }

    private func exportCompanions(
        _ resources: [PHAssetResource], primary: PHAssetResource, fileName: String, directory: URL
    ) async throws -> [ExportedResource] {
        var additional: [ExportedResource] = []
        for (index, resource) in resources.enumerated() where resource !== primary {
            try Task.checkCancellation()
            let ext = (resource.originalFilename as NSString).pathExtension
            let name = (fileName as NSString).deletingPathExtension
                + "__kphotos_resource_\(resource.type.rawValue)_\(index)." + (ext.isEmpty ? "dat" : ext)
            let url = directory.appendingPathComponent(name)
            try await writeResource(resource, to: url)
            additional.append(ExportedResource(
                fileURL: url,
                fileName: name,
                mimeType: Self.mimeType(from: resource.uniformTypeIdentifier),
                resourceType: resource.type.rawValue,
                originalFilename: resource.originalFilename
            ))
        }
        return additional
    }

    private static func resourceDescriptors(
        primary: PHAssetResource, fileName: String, additional: [ExportedResource]
    ) -> [[String: Any]] {
        let primaryDescriptor: [String: Any] = [
            "fileName": fileName,
            "originalFilename": primary.originalFilename,
            "resourceType": primary.type.rawValue
        ]
        return [primaryDescriptor] + additional.map {
            ["fileName": $0.fileName, "originalFilename": $0.originalFilename, "resourceType": $0.resourceType]
        }
    }

    private static func metadata(
        for asset: PHAsset,
        createdAt creationDate: Date,
        descriptors: [[String: Any]]
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "version": 1,
            "localIdentifier": asset.localIdentifier,
            "createdAt": creationDate.timeIntervalSince1970,
            "isFavorite": asset.isFavorite,
            "isHidden": asset.isHidden,
            "pixelWidth": asset.pixelWidth,
            "pixelHeight": asset.pixelHeight,
            "duration": asset.duration,
            "mediaType": asset.mediaType.rawValue,
            "mediaSubtypes": asset.mediaSubtypes.rawValue,
            "resources": descriptors
        ]
        if let date = asset.modificationDate { metadata["modifiedAt"] = date.timeIntervalSince1970 }
        if let id = asset.burstIdentifier { metadata["burstIdentifier"] = id }
        if let location = asset.location {
            metadata["location"] = [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "altitude": location.altitude,
                "horizontalAccuracy": location.horizontalAccuracy,
                "verticalAccuracy": location.verticalAccuracy
            ]
        }
        var albums: [[String: String]] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { album, _, _ in
                albums.append(["identifier": album.localIdentifier, "title": album.localizedTitle ?? ""])
            }
        metadata["albums"] = albums
        return metadata
    }

    // MARK: - Helpers

    static func primaryResource(in resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
    }

    static func makeFileName(
        creationDate: Date,
        localIdentifier: String,
        uniformTypeIdentifier: String,
        originalFilename: String
    ) -> String {
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
        case "public.jpeg": "image/jpeg"
        case "public.png": "image/png"
        case "public.heic", "public.heif": "image/heic"
        case "com.apple.quicktime-movie": "video/quicktime"
        case "public.mpeg-4": "video/mp4"
        default: UTType(uti)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    static func fileExtension(from uti: String) -> String {
        switch uti {
        case "public.jpeg": "jpg"
        case "public.png": "png"
        case "public.heic", "public.heif": "heic"
        case "com.apple.quicktime-movie": "mov"
        case "public.mpeg-4": "mp4"
        default: "dat"
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
