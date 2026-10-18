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
import Foundation
import ImageIO

public struct EmbeddedMediaMetadata: Codable, Equatable, Sendable {
    /// A new reader revision rechecks cached originals so existing cloud libraries gain Live Photo pairing.
    public var readerVersion: Int?
    public var partialRead: Bool?
    public var isPartial: Bool { partialRead ?? true }
    public var coordinate: MediaCoordinate?
    public var captureDate: Date?
    public var hasExplicitTimezone = false
    public var rawCaptureDate: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var isoSpeed: Int?
    public var focalLength: Double?
    public var duration: Double?
    public var livePhotoContentIdentifier: String?
    public var detectedImageType: String?
    public init() {}

    static func image(data: Data, complete: Bool = false) -> EmbeddedMediaMetadata? {
        let source = CGImageSourceCreateIncremental([kCGImageSourceShouldCache: false] as CFDictionary)
        CGImageSourceUpdateData(source, data as CFData, complete)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        var result = image(properties: props)
        result.detectedImageType = CGImageSourceGetType(source) as String?
        result.partialRead = !complete
        return result
    }

    static func image(url: URL) -> EmbeddedMediaMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        var result = image(properties: props)
        result.detectedImageType = CGImageSourceGetType(source) as String?
        return result
    }

    static func image(properties props: [String: Any]) -> EmbeddedMediaMetadata {
        var result = EmbeddedMediaMetadata(); result.partialRead = false; result.readerVersion = 2
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double,
           let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
           let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
           ["N", "S"].contains(latRef), ["E", "W"].contains(lonRef) {
            result.coordinate = MediaCoordinate(
                latitude: latRef == "S" ? -abs(lat) : abs(lat),
                longitude: lonRef == "W" ? -abs(lon) : abs(lon)
            )
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            result.rawCaptureDate = date
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.isLenient = false
            if let offset = exif["OffsetTimeOriginal"] as? String,
               offset.range(of: "^[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
                result.captureDate = formatter.date(from: date + offset)
                result.hasExplicitTimezone = result.captureDate != nil
            } else {
                // Keep the EXIF wall clock for local presentation, without claiming its UTC timezone.
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                result.captureDate = formatter.date(from: date)
            }
        }
        result.pixelWidth = props[kCGImagePropertyPixelWidth as String] as? Int
        result.pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int
        result.make = tiff[kCGImagePropertyTIFFMake as String] as? String
        result.model = tiff[kCGImagePropertyTIFFModel as String] as? String
        result.lens = exif[kCGImagePropertyExifLensModel as String] as? String
        result.fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double
        result.exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        result.isoSpeed = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        result.focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
        if let maker = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
           let identifier = maker["17"] as? String {
            result.livePhotoContentIdentifier = UUID(uuidString: identifier)?.uuidString
        }
        return result
    }

    static func iso6709(_ value: String) -> MediaCoordinate? {
        guard let regex =
            try? NSRegularExpression(
                pattern: "^([+-][0-9]{2}(?:\\.[0-9]+)?)([+-][0-9]{3}(?:\\.[0-9]+)?)(?:[+-][0-9]+(?:\\.[0-9]+)?)?/$"
            ),
            let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            let latRange = Range(match.range(at: 1), in: value), let lonRange = Range(match.range(at: 2), in: value),
            let latitude = Double(value[latRange]), let longitude = Double(value[lonRange]) else { return nil }
        return MediaCoordinate(latitude: latitude, longitude: longitude)
    }

    static func video(url: URL) async throws -> EmbeddedMediaMetadata {
        try await video(asset: AVURLAsset(url: url))
    }

    static func video(asset: AVURLAsset) async throws -> EmbeddedMediaMetadata {
        try await withTaskCancellationHandler {
            var result = EmbeddedMediaMetadata(); result.partialRead = false; result.readerVersion = 2
            let formats = try await asset.load(.availableMetadataFormats)
            var items: [AVMetadataItem] = []
            for format in formats {
                items += try await asset.loadMetadata(for: format)
            }
            for item in items {
                if item.identifier == .quickTimeMetadataContentIdentifier,
                   let identifier = try await item.load(.stringValue) {
                    result.livePhotoContentIdentifier = UUID(uuidString: identifier)?.uuidString
                } else if item.identifier == .quickTimeMetadataLocationISO6709
                    || item.identifier == .quickTimeUserDataLocationISO6709,
                    let text = try await item.load(.stringValue) {
                    result.coordinate = iso6709(text)
                } else if item.identifier == .quickTimeMetadataCreationDate || item.identifier == .quickTimeUserDataCreationDate
                    || item.identifier == .commonIdentifierCreationDate, let text = try await item.load(.stringValue) {
                    result.rawCaptureDate = text
                    let formatter = ISO8601DateFormatter()
                    result.captureDate = formatter.date(from: text)
                    if result.captureDate == nil {
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        result.captureDate = formatter.date(from: text)
                    }
                    result.hasExplicitTimezone = result.captureDate != nil
                }
            }
            let duration = try await asset.load(.duration).seconds
            if duration.isFinite { result.duration = duration }
            try Task.checkCancellation()
            return result
        } onCancel: { asset.cancelLoading()
        }
    }
}
