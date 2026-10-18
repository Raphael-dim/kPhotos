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
import RealmSwift

/// Politique réseau autorisée pour la synchronisation.
/// Modélisé en option-set pour autoriser indépendamment Wi-Fi et cellulaire,
/// ou les deux. Si le set est vide la sync est bloquée à l'exécution.
public struct SyncNetworkPolicy: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let wifi = SyncNetworkPolicy(rawValue: 1 << 0)
    public static let cellular = SyncNetworkPolicy(rawValue: 1 << 1)

    public static let wifiOnly: SyncNetworkPolicy = [.wifi]
    public static let unrestricted: SyncNetworkPolicy = [.wifi, .cellular]
}

/// Filtre du type de média synchronisé.
public struct SyncMediaFilter: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let photos = SyncMediaFilter(rawValue: 1 << 0)
    public static let videos = SyncMediaFilter(rawValue: 1 << 1)

    public static let photosOnly: SyncMediaFilter = [.photos]
    public static let videosOnly: SyncMediaFilter = [.videos]
    public static let both: SyncMediaFilter = [.photos, .videos]
}

/// Réglages utilisateur de synchronisation. Un seul objet (primaryKey=0).
public final class SyncSettings: Object {
    @Persisted(primaryKey: true)
    public var id: Int = 0

    /// Activer la sync automatique en background (BGAppRefreshTask).
    @Persisted public var isAutoSyncEnabled: Bool = false

    /// Autorisations réseau bit-packées (cf. SyncNetworkPolicy).
    /// Valeur par défaut : Wi-Fi uniquement — choix conservateur pour la data.
    @Persisted public var networkPolicyRaw: Int = SyncNetworkPolicy.wifiOnly.rawValue

    /// Filtre photo / vidéo bit-packé (cf. SyncMediaFilter).
    /// Valeur par défaut : les deux.
    @Persisted public var mediaFilterRaw: Int = SyncMediaFilter.both.rawValue

    /// Nom du dossier de destination dans l'espace Private du kDrive (paramétrable
    /// depuis Réglages). Vide = on retombe sur la constante par défaut.
    @Persisted public var rootFolderName: String = SyncSettingsSnapshot.defaultRootFolderName

    public var networkPolicy: SyncNetworkPolicy {
        get { SyncNetworkPolicy(rawValue: networkPolicyRaw) }
        set { networkPolicyRaw = newValue.rawValue }
    }

    public var mediaFilter: SyncMediaFilter {
        get { SyncMediaFilter(rawValue: mediaFilterRaw) }
        set { mediaFilterRaw = newValue.rawValue }
    }
}

/// Snapshot thread-safe — toujours utilisé hors d'un block Realm.
public struct SyncSettingsSnapshot: Equatable, Sendable {
    public var isAutoSyncEnabled: Bool
    public var networkPolicy: SyncNetworkPolicy
    public var mediaFilter: SyncMediaFilter
    public var rootFolderName: String

    public init(
        isAutoSyncEnabled: Bool,
        networkPolicy: SyncNetworkPolicy,
        mediaFilter: SyncMediaFilter,
        rootFolderName: String = SyncSettingsSnapshot.defaultRootFolderName
    ) {
        self.isAutoSyncEnabled = isAutoSyncEnabled
        self.networkPolicy = networkPolicy
        self.mediaFilter = mediaFilter
        self.rootFolderName = rootFolderName
    }

    public static let defaultRootFolderName = "kPhotos"

    /// Valeurs par défaut — utilisées au tout premier lancement avant qu'on écrive en base.
    public static let defaults = SyncSettingsSnapshot(
        isAutoSyncEnabled: false,
        networkPolicy: .wifiOnly,
        mediaFilter: .both,
        rootFolderName: defaultRootFolderName
    )

    init(_ entity: SyncSettings) {
        let stored = entity.rootFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            isAutoSyncEnabled: entity.isAutoSyncEnabled,
            networkPolicy: entity.networkPolicy,
            mediaFilter: entity.mediaFilter,
            rootFolderName: stored.isEmpty ? Self.defaultRootFolderName : stored
        )
    }
}
