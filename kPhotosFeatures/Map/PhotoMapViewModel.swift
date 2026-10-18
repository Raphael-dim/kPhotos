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
import Foundation
import kPhotosCore

/// A cloud photo with a confirmed portable or PhotoKit location.
/// On stocke lat/lon en `Double` (Sendable, contrairement à `CLLocationCoordinate2D`)
/// et on reconstruit la `CLLocationCoordinate2D` au moment d'instancier les
/// `MKAnnotation`.
public struct PhotoMapPoint: Identifiable, Equatable, Sendable {
    public let id: String // == fileId, pour Identifiable
    public let photo: PhotoSnapshot
    public let latitude: Double
    public let longitude: Double

    public init(photo: PhotoSnapshot, latitude: Double, longitude: Double) {
        self.id = photo.fileId
        self.photo = photo
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Groupe de photos partageant une localisation (cluster géographique large,
/// genre "même ville"). Sert à afficher la vue "Lieux" inspirée d'iOS Photos.
/// Le `placeName` est résolu asynchroniquement via CLGeocoder — il peut rester
/// nil pendant quelques secondes après le `load()`.
public struct PlaceGroup: Identifiable, Equatable, Sendable {
    public let id: String // hash stable du centre arrondi
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let photos: [PhotoSnapshot]
    public var placeName: String?

    public var photoCount: Int { photos.count }

    public init(id: String, centerLatitude: Double, centerLongitude: Double, photos: [PhotoSnapshot], placeName: String? = nil) {
        self.id = id
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.photos = photos
        self.placeName = placeName
    }
}

/// Map coordinates come from the preserved Takeout metadata or a linked local asset.
@MainActor
public final class PhotoMapViewModel: ObservableObject {
    public enum State: Equatable {
        case loading
        case permissionNeeded
        case permissionDenied
        case empty
        case ready(points: [PhotoMapPoint])
        case error(message: String)
    }

    @Published public private(set) var metadataProgress = MetadataIndexProgress()
    @Published public private(set) var state: State = .loading
    /// Lieux agrégés à partir des points — utilisés pour la vue "Lieux" en liste
    /// au-dessus de la minimap. Reconstruits à chaque `load()`. Les `placeName`
    /// se remplissent asynchroniquement via `resolvePlaceNames()`.
    @Published public private(set) var placeGroups: [PlaceGroup] = []

    @InjectService private var preparedIndex: PreparedMediaIndexSyncing
    @InjectService private var metadataIndexer: EmbeddedMetadataIndexing
    @InjectService private var driveManager: DriveManaging
    @InjectService private var photoReader: PhotoReading
    @InjectService private var assetReader: PHAssetReading

    @InjectService private var settings: SyncSettingsReading
    private var cancellables: Set<AnyCancellable> = []
    private var geocodingTask: Task<Void, Never>?
    private var loadGeneration = UUID()

    public init() {
        metadataIndexer.progressPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self else { return }
                // Preparation is shared, but its status must match the library shown here.
                let drive = try? driveManager.selectedDrive()
                let scope = drive.map { "\($0.id):\($0.rootFolderId)" }
                self.metadataProgress = progress.libraryScope == scope ? progress : MetadataIndexProgress()
            }.store(in: &cancellables)
        photoReader.changesPublisher
            .throttle(for: .seconds(10), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in Task { await self?.load() } }
            .store(in: &cancellables)
        settings.publisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.load() } }
            .store(in: &cancellables)
    }

    public func load() async {
        let selected = try? driveManager.selectedDrive()
        if metadataProgress.libraryScope != selected.map({ "\($0.id):\($0.rootFolderId)" }) {
            metadataProgress = MetadataIndexProgress()
        }
        Task {
            guard let drive = try? driveManager.selectedDrive(), !drive.rootFolderId.isEmpty else { return }
            do { try await preparedIndex.refresh(driveId: drive.id, rootId: drive.rootFolderId) } catch {
            /* Cached places remain available when the remote index is missing or unavailable. */ }
        }
        let generation = UUID()
        loadGeneration = generation
        geocodingTask?.cancel()
        state = .loading
        let knownNames = Dictionary(
            placeGroups.compactMap { group in group.placeName.map { (group.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        placeGroups = []
        let auth = assetReader.currentAuthorization()
        let cloudPhotos: [PhotoSnapshot]
        do {
            let drive = try driveManager.selectedDrive()
            cloudPhotos = try photoReader.allPhotos().filter {
                $0.isAvailable && $0.driveId == drive?.id && $0.libraryRootId == drive?.rootFolderId
            }
        } catch {
            state = .error(message: error.localizedDescription)
            return
        }
        // Cloud coordinates never require access to the iPhone photo library.
        let identifiers = cloudPhotos.filter { $0.coordinate == nil && !$0.localIdentifier.isEmpty }.map(\.localIdentifier)
        let locations = (auth == .authorized || auth == .limited)
            ? await assetReader.fetchLocations(forLocalIdentifiers: identifiers) : []
        guard generation == loadGeneration, !Task.isCancelled else { return }
        let points = Self.makePoints(photos: cloudPhotos, localLocations: locations)
        guard !points.isEmpty else {
            switch auth {
            case .notDetermined: state = .permissionNeeded
            case .denied, .restricted: state = .permissionDenied
            case .authorized, .limited: state = .empty
            }
            return
        }

        state = .ready(points: points)
        // Clustering géographique grossier pour obtenir une liste de "lieux".
        // ~50km de seuil : on regroupe à l'échelle ville/agglo. Si l'utilisateur
        // veut une granularité plus fine, on basculera vers la vue carte (clusters MapKit).
        let groups = await Task.detached(priority: .userInitiated) { Self.clusterIntoPlaces(points: points, radiusKm: 50) }.value
        guard generation == loadGeneration, !Task.isCancelled else { return }
        placeGroups = groups
        for index in placeGroups.indices {
            placeGroups[index].placeName = knownNames[placeGroups[index].id]
        }
        // Reverse-geocoding en arrière-plan, séquentiel pour respecter le rate
        // limit CLGeocoder (~1 req/s en pratique).
        geocodingTask = Task { await resolvePlaceNames(generation: generation) }
    }

    static func makePoints(photos: [PhotoSnapshot], localLocations: [AssetLocation]) -> [PhotoMapPoint] {
        var local: [String: AssetLocation] = [:]
        for location in localLocations {
            local[location.localIdentifier] = location
        }
        let pairs = LivePhotoPairing(photos: photos)
        return photos.filter { !pairs.motionFileIds.contains($0.fileId) }.compactMap { snapshot in
            let photo = pairs.attachMotion(to: snapshot)
            let fallback = local[photo.localIdentifier].flatMap {
                MediaCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            }
            let embedded = ["embedded", "photokit"].contains(photo.locationSource) ? photo.coordinate : nil
            guard let coordinate = embedded ?? fallback else { return nil }
            return PhotoMapPoint(photo: photo, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    public func stopMetadata() async { await metadataIndexer.stop() }

    public func retryMetadata() async {
        guard let drive = try? driveManager.selectedDrive(), !drive.rootFolderId.isEmpty else { return }
        await metadataIndexer.retry(driveId: drive.id, rootId: drive.rootFolderId)
    }

    public func requestPhotoLibraryAccess() async {
        _ = await assetReader.requestAuthorization()
        await load()
    }

    /// Triées anti-chronologiquement — utilisé pour le viewer ouvert depuis une
    /// annotation, pour avoir le swipe horizontal naturel comme dans Timeline.
    public func orderedPhotos(from points: [PhotoMapPoint]) -> [PhotoSnapshot] {
        points.map(\.photo).sorted { $0.takenAt > $1.takenAt }
    }

    /// Cherche le nom de lieu (résolu via CLGeocoder) du groupe contenant la
    /// première photo passée. Utilisé pour titrer le bottom sheet quand on
    /// arrive depuis un tap d'annotation MapKit (sans `PlaceGroup` sous la
    /// main). Renvoie nil si rien n'a encore été résolu.
    public func placeName(forAny photos: [PhotoSnapshot]) -> String? {
        let ids = Set(photos.map(\.fileId))
        return placeGroups.first { group in
            group.photos.contains { ids.contains($0.fileId) }
        }?.placeName
    }

    // MARK: - Place clustering

    /// Clustering greedy par distance Haversine. O(n²) — acceptable pour quelques
    /// centaines de photos. À optimiser (grid index) au-delà.
    private nonisolated static func clusterIntoPlaces(points: [PhotoMapPoint], radiusKm: Double) -> [PlaceGroup] {
        var clusters: [[PhotoMapPoint]] = []
        for point in points {
            // Cherche un cluster existant dont le centre est à <radiusKm.
            if let idx = clusters.firstIndex(where: { cluster in
                guard let first = cluster.first else { return false }
                return distanceKm(
                    lat1: first.latitude,
                    lon1: first.longitude,
                    lat2: point.latitude,
                    lon2: point.longitude
                ) < radiusKm
            }) {
                clusters[idx].append(point)
            } else {
                clusters.append([point])
            }
        }

        // Convertit chaque cluster en `PlaceGroup` avec son centre géographique
        // (moyenne arithmétique — suffisant à cette échelle).
        return clusters
            .map { cluster -> PlaceGroup in
                let lats = cluster.map(\.latitude)
                let lons = cluster.map(\.longitude)
                let centerLat = lats.reduce(0, +) / Double(lats.count)
                let centerLon = lons.reduce(0, +) / Double(lons.count)
                let photos = cluster
                    .map(\.photo)
                    .sorted { $0.takenAt > $1.takenAt }
                let id = String(format: "%.3f_%.3f", centerLat, centerLon)
                return PlaceGroup(
                    id: id,
                    centerLatitude: centerLat,
                    centerLongitude: centerLon,
                    photos: photos
                )
            }
            // Tri descendant par nombre de photos — les "tops localisations"
            // remontent en haut de la liste, comme dans Google Maps / iOS Photos.
            .sorted { $0.photoCount > $1.photoCount }
    }

    /// Formule de Haversine. Renvoie la distance en km entre deux points GPS.
    private nonisolated static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKm = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusKm * c
    }

    /// Résout `placeName` pour chaque groupe en séquentiel — CLGeocoder est rate-
    /// limited (sous le capot ~1 req/s côté Apple). On stoppe net si la View a
    /// disparu (Task annulée).
    private func resolvePlaceNames(generation: UUID) async {
        let geocoder = CLGeocoder()
        for (idx, group) in placeGroups.enumerated() {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if group.placeName != nil { continue }
            let location = CLLocation(latitude: group.centerLatitude, longitude: group.centerLongitude)
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first,
                   let name = Self.formatClusterAddress(placemark),
                   generation == loadGeneration, !Task.isCancelled,
                   idx < placeGroups.count, placeGroups[idx].id == group.id {
                    placeGroups[idx].placeName = name
                }
            } catch {
                continue
            }
            // Throttling défensif — CLGeocoder rejette en MKErrorDomain si trop rapide.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Adresse "ville + pays" pour un cluster (rayon ~50km). On évite la rue —
    /// elle n'a aucun sens à cette échelle (le centre du cluster n'est pas où
    /// se trouvent réellement les photos). Format type : "Paris, France" ou
    /// "Plainpalais, Genève" si on a un subLocality plus parlant.
    static func formatClusterAddress(_ placemark: CLPlacemark) -> String? {
        let primary = placemark.subLocality
            ?? placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
        let secondary: String? = {
            if let locality = placemark.locality, locality != primary { return locality }
            if let admin = placemark.administrativeArea, admin != primary { return admin }
            return placemark.country
        }()
        let parts = [primary, secondary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Adresse "fine" pour un point précis (annotation MapKit tappée). Inclut
    /// la rue / le nom du lieu si CLGeocoder le fournit. Format type :
    /// "12 Rue du Stand, Plainpalais, Genève".
    public static func formatPreciseAddress(_ placemark: CLPlacemark) -> String? {
        // Ligne 1 : numéro + rue, ou nom de lieu (POI) si dispo.
        let streetLine: String? = {
            if let thoroughfare = placemark.thoroughfare {
                if let number = placemark.subThoroughfare {
                    return "\(number) \(thoroughfare)"
                }
                return thoroughfare
            }
            return placemark.name
        }()
        // Ligne 2 : quartier ; ligne 3 : ville. Dédoublonnage en cas où
        // `name` reprend déjà la ville (CLPlacemark le fait parfois).
        var parts: [String] = []
        if let streetLine { parts.append(streetLine) }
        if let subLocality = placemark.subLocality, !parts.contains(subLocality) {
            parts.append(subLocality)
        }
        if let locality = placemark.locality, !parts.contains(locality) {
            parts.append(locality)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
