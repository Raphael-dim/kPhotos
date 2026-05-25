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

import Combine
import Foundation
import kPhotosCore

@MainActor
public final class SyncOptionsViewModel: ObservableObject {
    @Published public var isAutoSyncEnabled: Bool = false
    @Published public var allowsWiFi: Bool = true
    @Published public var allowsCellular: Bool = false
    @Published public var syncsPhotos: Bool = true
    @Published public var syncsVideos: Bool = true
    @Published public private(set) var errorMessage: String?

    @InjectService private var settingsReader: SyncSettingsReading
    @InjectService private var settingsWriter: SyncSettingsWriting
    @InjectService private var photoLibraryObserver: PhotoLibraryObserving

    private var cancellables: Set<AnyCancellable> = []
    /// Sentinel pour éviter une boucle infinie quand on republie ce que l'on
    /// vient d'écrire.
    private var isApplyingRemoteUpdate = false
    /// Dernier `mediaFilter` connu — sert à détecter une vraie modification du
    /// filtre média (vs un toggle réseau, qui ne nécessite pas de restart
    /// observer). Nil = première initialisation, pas de restart.
    private var lastKnownMediaFilter: SyncMediaFilter?

    public init() {
        bind()
    }

    private func bind() {
        // 1. Source de vérité Realm → état local. Si l'utilisateur change les
        //    réglages depuis ailleurs (settings de l'OS p.ex.), on reste sync.
        settingsReader.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.isApplyingRemoteUpdate = true
                self.isAutoSyncEnabled = snapshot.isAutoSyncEnabled
                self.allowsWiFi = snapshot.networkPolicy.contains(.wifi)
                self.allowsCellular = snapshot.networkPolicy.contains(.cellular)
                self.syncsPhotos = snapshot.mediaFilter.contains(.photos)
                self.syncsVideos = snapshot.mediaFilter.contains(.videos)
                self.isApplyingRemoteUpdate = false
            }
            .store(in: &cancellables)

        // 2. État local → Realm. Le debounce évite d'écrire à chaque tap pendant
        //    qu'un toggle SwiftUI anime, et coalesce les changements rapides.
        Publishers.CombineLatest4(
            $isAutoSyncEnabled,
            $allowsWiFi,
            $allowsCellular,
            Publishers.CombineLatest($syncsPhotos, $syncsVideos)
        )
        .dropFirst()
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] auto, wifi, cellular, mediaPair in
            guard let self, !self.isApplyingRemoteUpdate else { return }
            Task { await self.persist(auto: auto,
                                      wifi: wifi,
                                      cellular: cellular,
                                      photos: mediaPair.0,
                                      videos: mediaPair.1) }
        }
        .store(in: &cancellables)
    }

    private func persist(auto: Bool, wifi: Bool, cellular: Bool, photos: Bool, videos: Bool) async {
        // Garde-fous : on ne laisse pas l'utilisateur tout désactiver et se retrouver
        // dans un état où une sync ne fera jamais rien. On corrige silencieusement
        // (le ViewModel republiera la valeur effective via le publisher Realm).
        var policy: SyncNetworkPolicy = []
        if wifi { policy.insert(.wifi) }
        if cellular { policy.insert(.cellular) }
        if policy.isEmpty { policy = .wifiOnly }

        var media: SyncMediaFilter = []
        if photos { media.insert(.photos) }
        if videos { media.insert(.videos) }
        if media.isEmpty { media = .both }

        do {
            try await settingsWriter.update { snapshot in
                snapshot.isAutoSyncEnabled = auto
                snapshot.networkPolicy = policy
                snapshot.mediaFilter = media
            }
            // Si le filtre média a effectivement changé, on relance l'observer
            // PhotoKit : son `PHFetchResult` est figé au démarrage avec le
            // predicate de l'époque, donc un toggle photo→vidéo n'aurait aucun
            // effet sur les nouvelles photos prises tant qu'on ne re-fetch pas.
            if let previous = lastKnownMediaFilter, previous != media {
                photoLibraryObserver.restart()
            }
            lastKnownMediaFilter = media
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
