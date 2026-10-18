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

public protocol DriveManaging: AnyObject {
    func refreshFromServer() async throws -> [DriveSnapshot]
    func allDrives() throws -> [DriveSnapshot]
    func selectedDrive() throws -> DriveSnapshot?
    func selectDrive(id: Int) async throws

    /// Découvre l'espace `Private` (visibility="is_private_space") du drive sélectionné
    /// et met son ID en cache. La racine kDrive (id=1) n'est PAS writable —
    /// il faut écrire dans l'espace Private.
    /// Retourne l'ID de l'espace Private.
    func ensurePrivateSpace() async throws -> String

    /// Crée le dossier racine `kPhotos/` (ou nom configuré) dans l'espace Private
    /// s'il n'existe pas encore. Si le serveur répond 400/destination_already_exists,
    /// on retrouve le dossier par listing. Retourne l'ID (mémorisé sur `Drive.rootFolderId`).
    func ensureRootFolder(folderName: String) async throws -> String

    /// Invalide les `rootFolderId` mémorisés — à appeler quand l'utilisateur
    /// change le nom du dossier de destination dans les réglages.
    func selectRootFolder(id: String) async throws
    func existingRootFolder(folderName: String) async throws -> String
    func resetCachedRootFolders() async throws
}

public final class DriveManagerImpl: DriveManaging {
    private let realm: RealmAccessor
    private let api: PhotoApiFetching

    public init(realm: RealmAccessor, api: PhotoApiFetching) {
        self.realm = realm
        self.api = api
    }

    public func refreshFromServer() async throws -> [DriveSnapshot] {
        let remote = try await api.listDrives()

        try await realm.write { realm in
            // Préserver l'état "isSelected" et "rootFolderId" lors du refresh.
            let existing = realm.objects(Drive.self)
            var existingMap: [Int: DriveSnapshot] = [:]
            for drive in existing {
                existingMap[drive.id] = DriveSnapshot(drive)
            }
            let mapped = remote.map { Self.makeDrive(from: $0) }
            for drive in mapped {
                if let existing = existingMap[drive.id] {
                    drive.privateSpaceId = existing.privateSpaceId
                    drive.isSelected = existing.isSelected
                    drive.rootFolderId = existing.rootFolderId
                }
            }
            realm.add(mapped, update: .modified)
        }

        return try allDrives()
    }

    public func allDrives() throws -> [DriveSnapshot] {
        try realm.read { realm in
            realm.objects(Drive.self)
                .sorted(byKeyPath: "name")
                .map(DriveSnapshot.init)
        }
    }

    public func selectedDrive() throws -> DriveSnapshot? {
        try realm.read { realm in
            realm.objects(Drive.self)
                .filter("isSelected == true")
                .first
                .map(DriveSnapshot.init)
        }
    }

    public func selectDrive(id: Int) async throws {
        try await realm.write { realm in
            let drives = realm.objects(Drive.self)
            for drive in drives {
                drive.isSelected = (drive.id == id)
            }
        }
    }

    public func ensurePrivateSpace() async throws -> String {
        guard let drive = try selectedDrive() else { throw PhotoAPIError.invalidResponse }
        if !drive.privateSpaceId.isEmpty { return drive.privateSpaceId }

        // Liste la racine système (id=1) et cherche l'entrée avec visibility="is_private_space".
        var cursor: String?
        var foundId: String?
        repeat {
            let page = try await api.listFolder(driveId: drive.id, folderId: "1", cursor: cursor, limit: 100)
            if let priv = page.items.first(where: { $0.visibility == "is_private_space" && $0.isDirectory }) {
                foundId = priv.id
                break
            }
            cursor = page.nextCursor
        } while cursor != nil

        guard let privateId = foundId else {
            throw PhotoAPIError.server(statusCode: 0, message: "Espace Private introuvable dans la racine du drive \(drive.id).")
        }

        try await realm.write { realm in
            guard let stored = realm.object(ofType: Drive.self, forPrimaryKey: drive.id) else { return }
            stored.privateSpaceId = privateId
        }
        return privateId
    }

    public func selectRootFolder(id: String) async throws {
        guard !id.isEmpty, id != "1", let drive = try selectedDrive() else { throw PhotoAPIError.invalidResponse }
        // Validate access and directory type before persisting the exact selection.
        _ = try await api.listFolder(driveId: drive.id, folderId: id, cursor: nil, limit: 5)
        try await realm.write { realm in
            realm.object(ofType: Drive.self, forPrimaryKey: drive.id)?.rootFolderId = id
        }
    }

    public func existingRootFolder(folderName: String) async throws -> String {
        guard let drive = try selectedDrive() else { throw PhotoAPIError.invalidResponse }
        if !drive.rootFolderId.isEmpty { return drive.rootFolderId }
        let parent = try await ensurePrivateSpace()
        guard let id = try await findChildDirectory(driveId: drive.id, parentId: parent, name: folderName) else {
            throw PhotoAPIError.notFound
        }
        try await selectRootFolder(id: id)
        return id
    }

    public func ensureRootFolder(folderName: String) async throws -> String {
        guard let drive = try selectedDrive() else {
            throw PhotoAPIError.invalidResponse
        }
        if !drive.rootFolderId.isEmpty {
            return drive.rootFolderId
        }
        // 1. S'assurer qu'on a l'espace Private (parent writable).
        let privateId = try await ensurePrivateSpace()

        // 2. Créer le dossier dedans — si déjà présent côté serveur (cache local
        //    perdu, install fraîche sur un drive déjà utilisé…), on retombe sur
        //    une lecture pour récupérer son id au lieu de propager le 400.
        let folderId: String
        if let existing = try await findChildDirectory(driveId: drive.id, parentId: privateId, name: folderName) {
            try await selectRootFolder(id: existing)
            return existing
        }
        do {
            let dto = try await api.createDirectory(
                driveId: drive.id,
                name: folderName,
                parentId: privateId
            )
            folderId = dto.id
        } catch let error as PhotoAPIError where Self.isDestinationAlreadyExists(error) {
            guard let existing = try await findChildDirectory(
                driveId: drive.id,
                parentId: privateId,
                name: folderName
            ) else {
                throw error
            }
            folderId = existing
        }

        try await realm.write { realm in
            guard let stored = realm.object(ofType: Drive.self, forPrimaryKey: drive.id) else { return }
            stored.rootFolderId = folderId
        }
        return folderId
    }

    /// Invalide les `rootFolderId` mémorisés sur tous les drives — à appeler quand
    /// le nom du dossier change dans les réglages pour forcer la re-résolution.
    public func resetCachedRootFolders() async throws {
        try await realm.write { realm in
            for drive in realm.objects(Drive.self) {
                drive.rootFolderId = ""
            }
        }
    }

    private static func isDestinationAlreadyExists(_ error: PhotoAPIError) -> Bool {
        guard case .server(let code, _) = error else { return false }
        // Confirm the folder's existence with a listing instead of depending on private error bodies.
        return code == 400 || code == 409
    }

    private func findChildDirectory(driveId: Int, parentId: String, name: String) async throws -> String? {
        var cursor: String?
        repeat {
            let page = try await api.listFolder(driveId: driveId, folderId: parentId, cursor: cursor, limit: 100)
            if let match = page.items.first(where: { $0.isDirectory && $0.name == name }) {
                return match.id
            }
            cursor = page.nextCursor
        } while cursor != nil
        return nil
    }

    static func makeDrive(from dto: RemoteDriveDTO) -> Drive {
        let drive = Drive()
        drive.id = dto.id
        drive.name = dto.name
        drive.size = dto.size ?? 0
        drive.usedSize = dto.usedSize ?? 0
        drive.role = dto.role ?? ""
        drive.isInMaintenance = dto.isInMaintenance ?? false
        return drive
    }
}
