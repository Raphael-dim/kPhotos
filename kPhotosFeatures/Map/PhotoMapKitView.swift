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
import kPhotosCore
import MapKit
import Photos
import SwiftUI
import UIKit

// MARK: - PhotoAnnotation

/// Annotation MKMapView portant une `PhotoSnapshot`. Le `clusteringIdentifier`
/// (défini côté `PhotoAnnotationView`) déclenche le clustering natif iOS — MapKit
/// regroupe automatiquement les annotations proches en `MKClusterAnnotation`
/// quand on dézoome.
final class PhotoAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let photo: PhotoSnapshot
    var title: String? { nil }

    init(point: PhotoMapPoint) {
        self.coordinate = CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
        self.photo = point.photo
    }
}

// MARK: - PhotoMapKitView

/// Carte plein écran avec clustering natif iOS. Reçoit les `PhotoMapPoint` à
/// afficher et un callback de tap (single ou cluster) — la sélection des photos
/// à montrer dans le bottom sheet est déléguée au parent SwiftUI.
struct PhotoMapKitView: UIViewRepresentable {
    let points: [PhotoMapPoint]
    let onSelect: ([PhotoSnapshot]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll
        map.register(
            PhotoAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: PhotoAnnotationView.reuseIdentifier
        )
        map.register(
            PhotoClusterAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: PhotoClusterAnnotationView.reuseIdentifier
        )
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.sync(points: points, on: map)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let onSelect: ([PhotoSnapshot]) -> Void
        private var loadedIdentifiers: Set<String> = []
        private var didFitOnFirstLoad = false

        init(onSelect: @escaping ([PhotoSnapshot]) -> Void) {
            self.onSelect = onSelect
        }

        func sync(points: [PhotoMapPoint], on map: MKMapView) {
            // Diff minimal : on n'ajoute que les nouvelles annotations pour éviter
            // de tout recréer (sinon les animations de zoom flashent à chaque
            // re-render SwiftUI).
            let newIDs = Set(points.map(\.id))
            if newIDs == loadedIdentifiers { return }

            map.removeAnnotations(map.annotations)
            let annotations = points.map(PhotoAnnotation.init(point:))
            map.addAnnotations(annotations)
            loadedIdentifiers = newIDs

            // Au premier affichage, on cadre la carte sur l'ensemble des points
            // (avec un petit padding pour ne pas coller aux bords).
            if !didFitOnFirstLoad, !annotations.isEmpty {
                didFitOnFirstLoad = true
                map.showAnnotations(annotations, animated: false)
                // Léger zoom out pour aérer le cadrage initial
                let region = map.region
                let expanded = MKCoordinateRegion(
                    center: region.center,
                    span: MKCoordinateSpan(
                        latitudeDelta: region.span.latitudeDelta * 1.2,
                        longitudeDelta: region.span.longitudeDelta * 1.2
                    )
                )
                map.setRegion(expanded, animated: false)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PhotoClusterAnnotationView.reuseIdentifier,
                    for: cluster
                ) as? PhotoClusterAnnotationView
                view?.configure(with: cluster)
                return view
            }
            if let photoAnnotation = annotation as? PhotoAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PhotoAnnotationView.reuseIdentifier,
                    for: photoAnnotation
                ) as? PhotoAnnotationView
                view?.configure(with: photoAnnotation)
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // Déselectionne tout de suite pour permettre un re-tap du même point.
            defer { mapView.deselectAnnotation(view.annotation, animated: false) }

            if let cluster = view.annotation as? MKClusterAnnotation {
                let photos = cluster.memberAnnotations
                    .compactMap { ($0 as? PhotoAnnotation)?.photo }
                    .sorted { $0.takenAt > $1.takenAt }
                guard !photos.isEmpty else { return }
                onSelect(photos)
            } else if let single = view.annotation as? PhotoAnnotation {
                onSelect([single.photo])
            }
        }
    }
}

// MARK: - PhotoAnnotationView

/// Annotation rendue comme une mini-vignette carrée arrondie avec bordure
/// blanche et ombre douce — visuel à la Google Photos.
/// `clusteringIdentifier == "photo"` ⇒ MapKit groupe automatiquement les
/// annotations proches lors du dézoom.
final class PhotoAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "PhotoAnnotationView"
    private static let size: CGFloat = 52

    private let imageView = UIImageView()
    private let placeholderLayer = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "photo"
        displayPriority = .defaultHigh
        frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        centerOffset = CGPoint(x: 0, y: -Self.size / 2)
        setupChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupChrome() {
        backgroundColor = .white
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 4
        layer.masksToBounds = false

        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = 8
        imageView.layer.cornerCurve = .continuous
        imageView.layer.masksToBounds = true
        imageView.backgroundColor = .systemGray5
        addSubview(imageView)
    }

    func configure(with annotation: PhotoAnnotation) {
        self.annotation = annotation
        loadThumbnail(for: annotation.photo)
    }

    private func loadThumbnail(for photo: PhotoSnapshot) {
        let key = "\(photo.driveId)-\(photo.fileId)"
        if let cached = ThumbnailCache.shared.image(forKey: key) {
            imageView.image = cached
            return
        }
        // Lecture disque hors main pour ne pas bloquer le scroll de la carte.
        imageView.image = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let disk = ThumbnailCache.shared.diskImage(forKey: key)
            if let disk {
                ThumbnailCache.shared.store(disk, forKey: key)
                await MainActor.run { [weak self] in
                    // Vérifie qu'on n'a pas été recyclé sur une autre photo.
                    guard let self,
                          (self.annotation as? PhotoAnnotation)?.photo.fileId == photo.fileId
                    else { return }
                    self.imageView.image = disk
                }
            }
        }
    }
}

// MARK: - PhotoClusterAnnotationView

/// Cluster = vignette d'une photo du groupe + badge rond avec le nombre.
final class PhotoClusterAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "PhotoClusterAnnotationView"
    private static let size: CGFloat = 60

    private let imageView = UIImageView()
    private let countBadge = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .circle
        frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        centerOffset = CGPoint(x: 0, y: -Self.size / 2)
        setupChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupChrome() {
        backgroundColor = .white
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 3
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 5
        layer.masksToBounds = false

        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = 9
        imageView.layer.cornerCurve = .continuous
        imageView.layer.masksToBounds = true
        imageView.backgroundColor = .systemGray5
        addSubview(imageView)

        // Badge en haut à droite, débordant légèrement de la vignette.
        let badgeSize: CGFloat = 24
        countBadge.frame = CGRect(
            x: Self.size - badgeSize + 4, y: -4,
            width: badgeSize, height: badgeSize
        )
        countBadge.textAlignment = .center
        countBadge.font = .systemFont(ofSize: 11, weight: .bold)
        countBadge.textColor = .white
        countBadge.backgroundColor = .systemBlue
        countBadge.layer.cornerRadius = badgeSize / 2
        countBadge.layer.borderColor = UIColor.white.cgColor
        countBadge.layer.borderWidth = 2
        countBadge.layer.masksToBounds = true
        addSubview(countBadge)
    }

    func configure(with cluster: MKClusterAnnotation) {
        self.annotation = cluster
        let count = cluster.memberAnnotations.count
        // Format compact pour gros groupes : 1k, 10k…
        countBadge.text = count < 1_000 ? "\(count)" : "\(count / 1_000)k+"

        // Vignette : la photo la plus récente du cluster, pour avoir un aperçu
        // pertinent (les vieilles photos floues sont moins représentatives).
        let mostRecent = cluster.memberAnnotations
            .compactMap { ($0 as? PhotoAnnotation)?.photo }
            .max(by: { $0.takenAt < $1.takenAt })

        guard let photo = mostRecent else {
            imageView.image = nil
            return
        }
        let key = "\(photo.driveId)-\(photo.fileId)"
        if let cached = ThumbnailCache.shared.image(forKey: key) {
            imageView.image = cached
        } else {
            imageView.image = nil
            Task.detached(priority: .userInitiated) { [weak self] in
                let disk = ThumbnailCache.shared.diskImage(forKey: key)
                if let disk {
                    ThumbnailCache.shared.store(disk, forKey: key)
                    await MainActor.run { [weak self] in
                        guard let self,
                              let cluster = self.annotation as? MKClusterAnnotation,
                              cluster.memberAnnotations
                                  .compactMap({ ($0 as? PhotoAnnotation)?.photo })
                                  .max(by: { $0.takenAt < $1.takenAt })?.fileId == photo.fileId
                        else { return }
                        self.imageView.image = disk
                    }
                }
            }
        }
    }
}
