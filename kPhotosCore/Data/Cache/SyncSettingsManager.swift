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
import Foundation
import RealmSwift

public protocol SyncSettingsReading: AnyObject {
    /// Lecture synchrone (très rapide — 1 objet Realm).
    func current() throws -> SyncSettingsSnapshot

    /// Flux observable des changements. Publie immédiatement la valeur courante,
    /// puis à chaque écriture Realm. Utilisé par les ViewModels et par
    /// `BackgroundSyncScheduler` pour replanifier quand l'auto-sync est togglée.
    var publisher: AnyPublisher<SyncSettingsSnapshot, Never> { get }
}

public protocol SyncSettingsWriting: AnyObject {
    func update(_ mutate: @Sendable (inout SyncSettingsSnapshot) -> Void) async throws
}

public typealias SyncSettingsManaging = SyncSettingsReading & SyncSettingsWriting

public final class SyncSettingsManagerImpl: SyncSettingsManaging {
    private let realm: RealmAccessor
    private let subject = CurrentValueSubject<SyncSettingsSnapshot, Never>(.defaults)
    private var token: NotificationToken?

    public init(realm: RealmAccessor) {
        self.realm = realm
        bootstrap()
    }

    deinit { token?.invalidate() }

    public var publisher: AnyPublisher<SyncSettingsSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    public func current() throws -> SyncSettingsSnapshot {
        try realm.read { realm in
            if let entity = realm.object(ofType: SyncSettings.self, forPrimaryKey: 0) {
                return SyncSettingsSnapshot(entity)
            }
            return .defaults
        }
    }

    public func update(_ mutate: @Sendable (inout SyncSettingsSnapshot) -> Void) async throws {
        var snapshot = try current()
        mutate(&snapshot)
        try await realm.write { realm in
            let entity = realm.object(ofType: SyncSettings.self, forPrimaryKey: 0) ?? {
                let new = SyncSettings()
                realm.add(new, update: .modified)
                return new
            }()
            entity.isAutoSyncEnabled = snapshot.isAutoSyncEnabled
            entity.networkPolicy = snapshot.networkPolicy
            entity.mediaFilter = snapshot.mediaFilter
            entity.rootFolderName = snapshot.rootFolderName
        }
        // Republie après chaque écriture (la notif Realm couvrirait ça mais on garantit
        // l'ordre — le scheduler doit voir le nouveau snapshot avant la fin du await.).
        let fresh = try current()
        subject.send(fresh)
    }

    // MARK: - Realm observation

    /// Mise en place de l'observation Realm sur l'objet singleton.
    /// Si l'objet n'existe pas encore, on publie les defaults et on observera après
    /// la première écriture (couverte par `update`).
    private func bootstrap() {
        do {
            let snapshot = try current()
            subject.send(snapshot)

            let realmInstance = try Realm(configuration: realm.configuration)
            let results = realmInstance.objects(SyncSettings.self)
            token = results.observe { [weak self] change in
                guard let self else { return }
                switch change {
                case .initial(let settings), .update(let settings, _, _, _):
                    if let entity = settings.first(where: { $0.id == 0 }) {
                        subject.send(SyncSettingsSnapshot(entity))
                    }
                case .error:
                    break
                }
            }
        } catch {
            // Pas critique : on continue avec les defaults publiées en construction.
        }
    }
}
