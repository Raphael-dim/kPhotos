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
import kPhotosResources
import MapKit
import Photos
import SwiftUI
import UIKit

private struct MapPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - LocationMapPreview

/// Mini-map non interactive centrée sur la coordonnée. Utilise l'API
/// `Map(coordinateRegion:annotationItems:)` qui marche en iOS 16+
/// (deprecated en 17 mais toujours fonctionnelle, et plus simple que de
/// versionner deux implémentations).
private struct LocationMapPreview: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        let region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005))
        Group {
            if #available(iOS 17.0, *) {
                Map(position: .constant(.region(region)), interactionModes: []) {
                    Marker(L10n.Viewer.Info.locationSection, coordinate: coordinate)
                        .tint(.red)
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            } else {
                Map(
                    coordinateRegion: .constant(region),
                    interactionModes: [],
                    annotationItems: [MapPin(coordinate: coordinate)]
                ) { pin in
                    MapMarker(coordinate: pin.coordinate, tint: .red)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - InfoFormat (shared helpers)

/// Formatters partagés entre les vues d'info (cloud & local). Extraits ici pour
/// éviter de dupliquer la logique de présentation dans chaque vue concrète.
private enum InfoFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f.string(from: date)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func shutter(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        return "1/\(Int(round(1.0 / seconds))) s"
    }

    static func resolution(width: Int, height: Int) -> String {
        "\(width) × \(height) px"
    }
}

/// Ligne `label → value` standard utilisée par toutes les sections d'info.
private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Section "Localisation" partagée — mini-carte + reverse-geocoding + ouverture Plans.
/// Réutilisée par les vues d'info cloud et locale (DRY).
private struct LocationSection: View {
    let location: PhotoLocation

    var body: some View {
        Section(L10n.Viewer.Info.locationSection) {
            VStack(alignment: .leading, spacing: 8) {
                LocationMapPreview(coordinate: location.coordinate)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets())
                if let name = location.placeName, !name.isEmpty {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                }
                Text(String(
                    format: "%.5f, %.5f",
                    location.coordinate.latitude,
                    location.coordinate.longitude
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Button {
                    openInMaps()
                } label: {
                    Label(L10n.Viewer.Info.openInMaps, systemImage: "map")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: location.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = location.placeName ?? L10n.Viewer.Info.locationSection
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: location.coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        ])
    }
}

// MARK: - PhotoInfoView (dispatcher)

/// Point d'entrée unique : aiguille vers la fiche d'info adéquate selon que le
/// média est synchronisé sur kDrive ou présent uniquement dans la photothèque iOS.
struct PhotoInfoView: View {
    let media: ViewerMedia

    var body: some View {
        switch media {
        case .cloud(let snapshot):
            CloudPhotoInfoView(photo: snapshot)
        case .local(let asset):
            LocalPhotoInfoView(asset: asset)
        }
    }
}

// MARK: - CloudPhotoInfoView

private struct CloudPhotoInfoView: View {
    let photo: PhotoSnapshot
    @StateObject private var vm: PhotoInfoViewModel

    init(photo: PhotoSnapshot) {
        self.photo = photo
        _vm = StateObject(wrappedValue: PhotoInfoViewModel(photo: photo))
    }

    var body: some View {
        List {
            fileSection
            dateSection
            if photo.isVideo { videoSection }
            if let exif = vm.exif, hasAnyCameraData(exif) { cameraSection(exif) }
            if let loc = vm.location { LocationSection(location: loc) }
            if let detail = vm.fileDetail { driveSection(detail) }
        }
        .task { await vm.load() }
        .overlay {
            if vm.isLoading, vm.fileDetail == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding()
            }
        }
    }

    private var fileSection: some View {
        Section(L10n.Viewer.Info.fileSection) {
            InfoRow(label: L10n.Viewer.Info.name, value: photo.name)
            InfoRow(label: L10n.Viewer.Info.type, value: photo.isVideo ? L10n.Viewer.Info.videoType : L10n.Viewer.Info.photoType)
            InfoRow(label: L10n.Viewer.Info.size, value: InfoFormat.size(photo.size))
            if let exif = vm.exif, let w = exif.pixelWidth, let h = exif.pixelHeight {
                InfoRow(label: L10n.Viewer.Info.resolution, value: InfoFormat.resolution(width: w, height: h))
            }
        }
    }

    private var dateSection: some View {
        Section(L10n.Viewer.Info.dateSection) {
            InfoRow(
                label: vm.originalMetadata?.captureDate != nil
                    ?
                    (
                        vm.originalMetadata?.hasExplicitTimezone == true ? L10n.Viewer.Info.takenAt : L10n.Viewer.Info
                            .embeddedLocalDate
                    )
                    : (photo.hasReliableCaptureDate ? L10n.Viewer.Info.takenAt : L10n.Viewer.Info.fallbackDate),
                value: InfoFormat.date(vm.originalMetadata?.captureDate ?? photo.takenAt)
            )
            if vm.originalMetadata?.captureDate != nil, vm.originalMetadata?.hasExplicitTimezone == false {
                Text(L10n.Viewer.Info.embeddedLocalDateExplanation).font(.footnote).foregroundStyle(.secondary)
            } else if vm.originalMetadata?.captureDate == nil, !photo.hasReliableCaptureDate {
                Text(L10n.Viewer.Info.fallbackDateExplanation).font(.footnote).foregroundStyle(.secondary)
            }
            InfoRow(label: L10n.Viewer.Info.addedAt, value: InfoFormat.date(photo.uploadedAt))
        }
    }

    private var videoSection: some View {
        Section(L10n.Viewer.Info.videoSection) {
            InfoRow(label: L10n.Viewer.Info.duration, value: InfoFormat.duration(photo.duration))
        }
    }

    @ViewBuilder
    private func cameraSection(_ exif: ExifMetadata) -> some View {
        Section(L10n.Viewer.Info.cameraSection) {
            if let make = exif.make, let model = exif.model {
                InfoRow(label: L10n.Viewer.Info.make, value: "\(make) \(model)")
            } else if let model = exif.model {
                InfoRow(label: L10n.Viewer.Info.make, value: model)
            }
            if let lens = exif.lens {
                InfoRow(label: L10n.Viewer.Info.lens, value: lens)
            }
            if let f = exif.fNumber {
                InfoRow(label: L10n.Viewer.Info.aperture, value: String(format: "f/%.1f", f))
            }
            if let t = exif.exposureTime {
                InfoRow(label: L10n.Viewer.Info.shutter, value: InfoFormat.shutter(t))
            }
            if let iso = exif.isoSpeed {
                InfoRow(label: L10n.Viewer.Info.iso, value: "\(iso)")
            }
            if let fl = exif.focalLength {
                InfoRow(label: L10n.Viewer.Info.focalLength, value: String(format: "%.0f mm", fl))
            }
        }
    }

    @ViewBuilder
    private func driveSection(_ detail: RemoteFileDetailDTO) -> some View {
        Section(L10n.Viewer.Info.kdriveSection) {
            if let path = detail.path {
                InfoRow(label: L10n.Viewer.Info.path, value: path)
            }
            if let hash = detail.hash {
                InfoRow(label: L10n.Viewer.Info.hash, value: String(hash.prefix(16)) + "…")
            }
        }
    }

    private func hasAnyCameraData(_ exif: ExifMetadata) -> Bool {
        exif.make != nil || exif.model != nil || exif.lens != nil
            || exif.fNumber != nil || exif.exposureTime != nil
            || exif.isoSpeed != nil || exif.focalLength != nil
    }
}

// MARK: - LocalPhotoInfoView

/// Fiche d'info simplifiée pour un média local-only (pas encore uploadé).
/// On affiche uniquement ce qui est lisible depuis PhotoKit sans tape sur l'API
/// kDrive : type, date, dimensions, durée (vidéo), localisation. Pas de section
/// "Fichier kDrive" ni de section "Appareil photo" (lecture EXIF du binaire
/// original = coût disque + permission, écarté volontairement pour rester léger).
private struct LocalPhotoInfoView: View {
    let asset: LocalAssetSnapshot
    @StateObject private var vm: LocalPhotoInfoViewModel

    init(asset: LocalAssetSnapshot) {
        self.asset = asset
        _vm = StateObject(wrappedValue: LocalPhotoInfoViewModel(asset: asset))
    }

    var body: some View {
        List {
            fileSection
            dateSection
            if asset.isVideo, let duration = vm.duration { videoSection(duration: duration) }
            if let loc = vm.location { LocationSection(location: loc) }
        }
        .task { await vm.load() }
    }

    private var fileSection: some View {
        Section(L10n.Viewer.Info.fileSection) {
            InfoRow(label: L10n.Viewer.Info.type, value: asset.isVideo ? L10n.Viewer.Info.videoType : L10n.Viewer.Info.photoType)
            if let width = vm.pixelWidth, let height = vm.pixelHeight {
                InfoRow(
                    label: L10n.Viewer.Info.resolution,
                    value: InfoFormat.resolution(width: width, height: height)
                )
            }
        }
    }

    private var dateSection: some View {
        Section(L10n.Viewer.Info.dateSection) {
            InfoRow(label: L10n.Viewer.Info.takenAt, value: InfoFormat.date(asset.takenAt))
        }
    }

    private func videoSection(duration: Double) -> some View {
        Section(L10n.Viewer.Info.videoSection) {
            InfoRow(label: L10n.Viewer.Info.duration, value: InfoFormat.duration(duration))
        }
    }
}
