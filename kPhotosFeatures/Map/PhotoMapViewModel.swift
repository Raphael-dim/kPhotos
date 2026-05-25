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
 */

import CoreLocation
import Foundation
import kPhotosCore

/// Point sur la carte = une photo kDrive qui a une localisation connue (via PhotoKit).
/// On stocke lat/lon en `Double` (Sendable, contrairement à `CLLocationCoordinate2D`)
/// et on reconstruit la `CLLocationCoordinate2D` au moment d'instancier les
/// `MKAnnotation`.
public struct PhotoMapPoint: Identifiable, Equatable, Sendable {
    public let id: String  // == fileId, pour Identifiable
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
    public let id: String  // hash stable du centre arrondi
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

/// ViewModel de la page Carte. Croise les photos kDrive (Realm) avec les
/// `PHAsset.location` correspondants — la seule source fiable de GPS car les
/// previews server-side de kDrive sont généralement strippés de leurs EXIF.
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

    @Published public private(set) var state: State = .loading
    /// Lieux agrégés à partir des points — utilisés pour la vue "Lieux" en liste
    /// au-dessus de la minimap. Reconstruits à chaque `load()`. Les `placeName`
    /// se remplissent asynchroniquement via `resolvePlaceNames()`.
    @Published public private(set) var placeGroups: [PlaceGroup] = []

    @InjectService private var photoReader: PhotoReading
    @InjectService private var assetReader: PHAssetReading

    public init() {}

    public func load() async {
        state = .loading

        let auth = assetReader.currentAuthorization()
        switch auth {
        case .notDetermined:
            state = .permissionNeeded
            return
        case .denied, .restricted:
            state = .permissionDenied
            return
        case .authorized, .limited:
            break
        }

        let cloudPhotos = (try? photoReader.allPhotos()) ?? []
        // Seules les photos qui ont un localIdentifier non vide ont une chance
        // d'être matchées avec un PHAsset. Pour les photos uploadées depuis le
        // web (sans passage par cette app), on n'a aucune info GPS exploitable.
        let withLocalID = cloudPhotos.filter { !$0.localIdentifier.isEmpty }
        guard !withLocalID.isEmpty else {
            state = .empty
            return
        }

        let identifiers = withLocalID.map(\.localIdentifier)
        let locations = await assetReader.fetchLocations(forLocalIdentifiers: identifiers)

        // Index locId → AssetLocation pour un join O(n).
        let locationByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.localIdentifier, $0) })

        let points: [PhotoMapPoint] = withLocalID.compactMap { photo in
            guard let loc = locationByID[photo.localIdentifier] else { return nil }
            return PhotoMapPoint(photo: photo, latitude: loc.latitude, longitude: loc.longitude)
        }

        if points.isEmpty {
            state = .empty
            placeGroups = []
            return
        }

        state = .ready(points: points)
        // Clustering géographique grossier pour obtenir une liste de "lieux".
        // ~50km de seuil : on regroupe à l'échelle ville/agglo. Si l'utilisateur
        // veut une granularité plus fine, on basculera vers la vue carte (clusters MapKit).
        placeGroups = Self.clusterIntoPlaces(points: points, radiusKm: 50)
        // Reverse-geocoding en arrière-plan, séquentiel pour respecter le rate
        // limit CLGeocoder (~1 req/s en pratique).
        Task { await resolvePlaceNames() }
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
    private static func clusterIntoPlaces(points: [PhotoMapPoint], radiusKm: Double) -> [PlaceGroup] {
        var clusters: [[PhotoMapPoint]] = []
        for point in points {
            // Cherche un cluster existant dont le centre est à <radiusKm.
            if let idx = clusters.firstIndex(where: { cluster in
                guard let first = cluster.first else { return false }
                return distanceKm(
                    lat1: first.latitude, lon1: first.longitude,
                    lat2: point.latitude, lon2: point.longitude
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
    private static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
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
    private func resolvePlaceNames() async {
        let geocoder = CLGeocoder()
        for (idx, group) in placeGroups.enumerated() {
            let location = CLLocation(latitude: group.centerLatitude, longitude: group.centerLongitude)
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let placemark = placemarks.first,
                   let name = Self.formatClusterAddress(placemark),
                   idx < placeGroups.count {
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
