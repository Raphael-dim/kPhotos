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

import Combine
import CoreLocation
import kPhotosCore
import Photos
import SwiftUI

struct ViewerLocationView: View {
    @StateObject private var viewModel: ViewerLocationViewModel

    init(media: ViewerMedia) {
        _viewModel = StateObject(wrappedValue: ViewerLocationViewModel(media: media))
    }

    var body: some View {
        Group {
            if let location = viewModel.location {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onAppear { viewModel.refresh() }
        .onReceive(viewModel.changesPublisher) { viewModel.refresh() }
        .task(id: viewModel.coordinate) { await viewModel.resolvePlaceName() }
    }
}

@MainActor
private final class ViewerLocationViewModel: ObservableObject {
    @Published private(set) var coordinate: MediaCoordinate?
    @Published private(set) var location: String?

    @InjectService private var photos: PhotoReading
    private let media: ViewerMedia

    var changesPublisher: AnyPublisher<Void, Never> { photos.changesPublisher }

    init(media: ViewerMedia) {
        self.media = media
    }

    func refresh() {
        let nextCoordinate: MediaCoordinate?
        switch media {
        case .cloud(let snapshot):
            do {
                let photo = try photos.photo(byFileId: snapshot.fileId) ?? snapshot
                nextCoordinate = originalCoordinate(photo)
            } catch {
                // The viewer can still use its snapshot if the index is temporarily unavailable.
                nextCoordinate = originalCoordinate(snapshot)
            }
        case .local(let asset):
            nextCoordinate = localCoordinate(identifier: asset.localIdentifier)
        }
        guard nextCoordinate != coordinate else { return }
        coordinate = nextCoordinate
        location = nextCoordinate.map { String(format: "%.4f, %.4f", $0.latitude, $0.longitude) }
    }

    func resolvePlaceName() async {
        guard let coordinate else { return }
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            guard !Task.isCancelled, self.coordinate == coordinate, let placemark = placemarks.first else { return }
            let parts = [placemark.locality ?? placemark.name, placemark.country].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { location = parts.joined(separator: ", ") }
        } catch {
            // Coordinates remain visible when geocoding is unavailable or cancelled.
        }
    }

    private func originalCoordinate(_ photo: PhotoSnapshot) -> MediaCoordinate? {
        let embedded = ["embedded", "photokit"].contains(photo.locationSource) ? photo.coordinate : nil
        return embedded ?? localCoordinate(identifier: photo.localIdentifier)
    }

    private func localCoordinate(identifier: String) -> MediaCoordinate? {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard !identifier.isEmpty, authorization == .authorized || authorization == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let location = asset.location else { return nil }
        return MediaCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
}
