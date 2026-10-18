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
import CoreLocation
import ImageIO
import kPhotosCore
import MapKit
import Photos
import SwiftUI
import UIKit

// MARK: - ExifMetadata

struct ExifMetadata: Sendable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let make: String?
    let model: String?
    let lens: String?
    let fNumber: Double?
    let exposureTime: Double?
    let isoSpeed: Int?
    let focalLength: Double?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
}

// MARK: - PhotoLocation

/// Localisation résolue d'une photo. `placeName` est rempli en différé par le
/// reverse geocoding (peut rester nil si Apple ne renvoie rien d'utile, ex: en
/// pleine mer, ou si la requête CLGeocoder est rate-limitée).
struct PhotoLocation: Equatable {
    let coordinate: CLLocationCoordinate2D
    var placeName: String?

    static func == (lhs: PhotoLocation, rhs: PhotoLocation) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.placeName == rhs.placeName
    }
}

// MARK: - PhotoInfoViewModel

@MainActor
final class PhotoInfoViewModel: ObservableObject {
    @Published private(set) var fileDetail: RemoteFileDetailDTO?
    @Published private(set) var originalMetadata: EmbeddedMediaMetadata?
    @Published private(set) var exif: ExifMetadata?
    @Published private(set) var location: PhotoLocation?
    @Published private(set) var isLoading = false

    private let photo: PhotoSnapshot
    @InjectService private var api: PhotoApiFetching
    @InjectService private var photoWriter: PhotoWriting

    init(photo: PhotoSnapshot) {
        self.photo = photo
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let driveId = photo.driveId
        let fileId = photo.fileId
        let localId = photo.localIdentifier

        async let detailTask = api.fileInfo(driveId: driveId, fileId: fileId)
        async let exifTask: ExifMetadata? = Self.extractExifFromPHAsset(localIdentifier: localId)

        fileDetail = try? await detailTask
        let parsedExif = await exifTask
        exif = parsedExif
        if let cached = photo.embeddedMetadata, photo.embeddedMetadataRevision == photo.remoteRevision {
            originalMetadata = cached
        } else {
            originalMetadata = try? await api.originalMetadata(driveId: driveId, fileId: fileId, isVideo: photo.isVideo)
            if let originalMetadata {
                try? await photoWriter.updateEmbeddedMetadata(
                    driveId: driveId,
                    fileId: fileId,
                    revision: photo.remoteRevision,
                    metadata: originalMetadata
                )
            }
        }
        if let original = originalMetadata, !photo.isVideo {
            exif = ExifMetadata(
                pixelWidth: original.pixelWidth,
                pixelHeight: original.pixelHeight,
                make: original.make,
                model: original.model,
                lens: original.lens,
                fNumber: original.fNumber,
                exposureTime: original.exposureTime,
                isoSpeed: original.isoSpeed,
                focalLength: original.focalLength,
                gpsLatitude: original.coordinate?.latitude,
                gpsLongitude: original.coordinate?.longitude
            )
        }

        if let coordinate = originalMetadata?.coordinate {
            location = PhotoLocation(
                coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                placeName: nil
            )
        } else if let coord = Self.locationFromPHAsset(localIdentifier: localId) {
            location = PhotoLocation(coordinate: coord, placeName: nil)
        } else if let lat = parsedExif?.gpsLatitude, let lon = parsedExif?.gpsLongitude,
                  let coordinate = MediaCoordinate(latitude: lat, longitude: lon) {
            location = PhotoLocation(
                coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                placeName: nil
            )
        }

        if let coord = location?.coordinate {
            let name = await Self.reverseGeocode(coord)
            // Re-check : la coord est toujours la même (l'utilisateur n'a pas
            // swipé vers une autre photo entre temps — protégé par @MainActor).
            if location?.coordinate.latitude == coord.latitude {
                location?.placeName = name
            }
        }
    }

    /// Lit `PHAsset.location` pour la photo si elle est encore présente dans la
    /// photothèque iOS. Renvoie nil si l'accès Photos n'a pas été accordé ou si
    /// l'asset n'existe plus localement (photo uploadée puis supprimée du device).
    private static func locationFromPHAsset(localIdentifier: String) -> CLLocationCoordinate2D? {
        guard !localIdentifier.isEmpty else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject, let loc = asset.location else { return nil }
        return loc.coordinate
    }

    /// Reverse-geocode une coordonnée vers une chaîne lisible "Lieu, Ville, Pays".
    /// CLGeocoder est rate-limité (50 req/min) — on encaisse silencieusement
    /// si Apple refuse.
    private static func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        let parts = [
            placemark.name, // ex: "Tour Eiffel" ou "5 Avenue Anatole France"
            placemark.locality, // ville
            placemark.country // pays
        ].compactMap { $0 }.filter { !$0.isEmpty }
        // Dédup : `name` peut déjà contenir la ville
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    nonisolated static func extractExifFromPHAsset(localIdentifier: String) async -> ExifMetadata? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let url: URL? = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false // jamais de download iCloud — métadonnées only
            options.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.fullSizeImageURL)
            }
        }
        guard let url else { return nil }

        let cgOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, cgOptions),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return parseExif(properties: props)
    }

    /// Cœur du parsing EXIF — partagé entre les sources Data et URL.
    nonisolated static func parseExif(properties props: [String: Any]) -> ExifMetadata? {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        // Les iPhone récents exposent les infos d'objectif via le bloc
        // ExifAux (lens make/model) ET ExifDictionary (LensModel). On regarde
        // les deux pour maximiser la couverture.
        let exifAux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]

        let make = tiff?[kCGImagePropertyTIFFMake as String] as? String
        let model = tiff?[kCGImagePropertyTIFFModel as String] as? String
        let lens = (exif?[kCGImagePropertyExifLensModel as String] as? String)
            ?? (exifAux?["LensModel"] as? String)
        let fNumber = exif?[kCGImagePropertyExifFNumber as String] as? Double
        let exposureTime = exif?[kCGImagePropertyExifExposureTime as String] as? Double
        let isoSpeed = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        let focalLength = exif?[kCGImagePropertyExifFocalLength as String] as? Double
        let pixelWidth = props[kCGImagePropertyPixelWidth as String] as? Int
        let pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int

        var gpsLat = gps?[kCGImagePropertyGPSLatitude as String] as? Double
        var gpsLon = gps?[kCGImagePropertyGPSLongitude as String] as? Double
        if let ref = gps?[kCGImagePropertyGPSLatitudeRef as String] as? String, ref == "S" { gpsLat = gpsLat.map { -$0 } }
        if let ref = gps?[kCGImagePropertyGPSLongitudeRef as String] as? String, ref == "W" { gpsLon = gpsLon.map { -$0 } }

        let hasData = make != nil || model != nil || lens != nil || fNumber != nil
            || pixelWidth != nil || gpsLat != nil
        guard hasData else { return nil }

        return ExifMetadata(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            make: make,
            model: model,
            lens: lens,
            fNumber: fNumber,
            exposureTime: exposureTime,
            isoSpeed: isoSpeed,
            focalLength: focalLength,
            gpsLatitude: gpsLat,
            gpsLongitude: gpsLon
        )
    }
}

// MARK: - LocalPhotoInfoViewModel

@MainActor
final class LocalPhotoInfoViewModel: ObservableObject {
    @Published private(set) var pixelWidth: Int?
    @Published private(set) var pixelHeight: Int?
    @Published private(set) var duration: Double?
    @Published private(set) var location: PhotoLocation?

    private let asset: LocalAssetSnapshot

    init(asset: LocalAssetSnapshot) {
        self.asset = asset
    }

    func load() async {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
        guard let phAsset = fetch.firstObject else { return }

        pixelWidth = phAsset.pixelWidth
        pixelHeight = phAsset.pixelHeight
        if phAsset.mediaType == .video {
            duration = phAsset.duration
        }
        if let coord = phAsset.location?.coordinate {
            location = PhotoLocation(coordinate: coord, placeName: nil)
            let name = await Self.reverseGeocode(coord)
            if location?.coordinate.latitude == coord.latitude {
                location?.placeName = name
            }
        }
    }

    /// Même stratégie que `PhotoInfoViewModel.reverseGeocode` — toléré silencieusement
    /// si CLGeocoder rate-limit.
    private static func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }
        let parts = [placemark.name, placemark.locality, placemark.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}
