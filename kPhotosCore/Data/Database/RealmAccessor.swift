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

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation
import RealmSwift
import Security

public protocol RealmAccessor: AnyObject {
    /// Lecture sur le thread courant. À utiliser depuis le main thread pour les writes UI.
    func read<T>(_ block: (Realm) throws -> T) throws -> T

    /// Écriture en background context. Jamais appelé depuis le main thread.
    func write(_ block: @escaping (Realm) throws -> Void) async throws

    /// Variante avec valeur de retour — pour les actions en masse qui veulent
    /// rapporter un compteur (ex: "X items requeued"). La valeur retournée doit
    /// être `Sendable` (value types uniquement, JAMAIS d'objet Realm managé).
    func writeReturning<T: Sendable>(_ block: @escaping (Realm) throws -> T) async throws -> T

    /// Configuration utilisée pour ouvrir Realm. Exposée pour les tests.
    var configuration: Realm.Configuration { get }
}

public final class RealmAccessorImpl: RealmAccessor {
    public let configuration: Realm.Configuration

    private let writeQueue = DispatchQueue(label: "app.kphotos.realm.write",
                                           qos: .utility)

    public init(configuration: Realm.Configuration = .defaultKPhotos) {
        self.configuration = configuration
    }

    public func read<T>(_ block: (Realm) throws -> T) throws -> T {
        let realm = try Realm(configuration: configuration)
        return try block(realm)
    }

    public func write(_ block: @escaping (Realm) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    let realm = try Realm(configuration: self.configuration)
                    try realm.write {
                        try block(realm)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func writeReturning<T: Sendable>(_ block: @escaping (Realm) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            writeQueue.async {
                do {
                    let realm = try Realm(configuration: self.configuration)
                    var captured: T?
                    try realm.write {
                        captured = try block(realm)
                    }
                    // `realm.write` exécute le block synchroniquement avant de
                    // commit — `captured` est non-nil ici sauf si le block a
                    // throw, mais dans ce cas on n'arrive pas ici (catch dessous).
                    continuation.resume(returning: captured!)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public extension Realm.Configuration {
    static var defaultKPhotos: Realm.Configuration {
        var config = Realm.Configuration.defaultConfiguration
        // v2: added Drive.privateSpaceId (cf. AGENTS.md §8 — arborescence kDrive : root → Private → user dirs).
        // v3: added SyncSettings (toggles auto-sync + politique réseau + filtre photo/vidéo).
        // v4: added SyncSettings.rootFolderName (dossier de destination paramétrable).
        // v5: (DEV-only) FailedUpload — jamais shipé, remplacé par BackupItem en v6.
        // v6: introduced BackupItem (file de sauvegarde persistante, source unique de
        //     vérité du statut local. Supersede `UploadQueue` in-memory : un asset y
        //     entre à l'enqueue et n'en sort qu'une fois `completed` ou explicitement
        //     `skipped`). Migration depuis v4/v5 = no-op (les données FailedUpload
        //     dev-only sont ignorées car le type n'est plus dans `objectTypes`).
        // v7: added BackupItem.nextRetryAt (optional Date) + state `.failedTransient`
        //     pour le retry exponentiel par item. Migration purement additive — Realm
        //     ajoute la colonne avec default nil.
        // v8: introduced DeletionItem (file de suppression persistante, symétrique à
        //     BackupItem). Indexée par `fileId` kDrive. Permet la reprise des suppressions
        //     après crash, retry/backoff, et le badge "deletion in progress" côté UI.
        //     Migration purement additive (nouvelle table, créée vide).
        config.schemaVersion = 8
        config.objectTypes = [Photo.self, Album.self, SyncCheckpoint.self, Drive.self, SyncSettings.self, BackupItem.self, DeletionItem.self]
        config.migrationBlock = { _, _ in
            // No-op : Realm gère automatiquement l'ajout de `BackupItem` / `DeletionItem`
            // (tables créées vides). Les éventuelles tables orphelines sont conservées
            // sur disque mais inaccessibles sans déclaration dans `objectTypes`.
        }
        config.fileURL = Self.kPhotosRealmURL()
        // Chiffrement at-rest : clé 64-byte stockée en Keychain (ThisDeviceOnly).
        // Sans ça, l'inventaire kDrive (fileIds, takenAt, paths) serait lisible
        // dès qu'un attaquant a accès au fichier `kPhotos.realm` post-unlock.
        // Si la clé n'est pas dispo (cas extrêmement rare — Keychain HS), on
        // tombe sur du Realm non chiffré plutôt que crasher.
        if let key = Self.kPhotosRealmEncryptionKey() {
            config.encryptionKey = key
        }
        return config
    }

    /// Charge la clé de chiffrement Realm depuis le Keychain, ou en génère
    /// une nouvelle si elle n'existe pas encore. 64 octets — taille exigée
    /// par Realm. Stockage `ThisDeviceOnly` → la clé ne suit pas les backups
    /// iCloud, et un device wipe = perte définitive (cohérent avec une cache
    /// reconstructible depuis kDrive).
    private static func kPhotosRealmEncryptionKey() -> Data? {
        let service = "app.kphotos.realm"
        let account = "encryptionKey"
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var loadQuery = baseQuery
        loadQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        loadQuery[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 64 {
            return data
        }

        var bytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let newKey = Data(bytes)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = newKey
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return nil }
        return newKey
    }

    /// Construit le chemin du fichier Realm en s'assurant que le dossier parent existe.
    /// `Library/Application Support/` n'est pas créé automatiquement dans la sandbox iOS.
    private static func kPhotosRealmURL() -> URL? {
        let fileManager = FileManager.default
        guard let supportDir = fileManager.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first else {
            return nil
        }
        if !fileManager.fileExists(atPath: supportDir.path) {
            try? fileManager.createDirectory(at: supportDir,
                                             withIntermediateDirectories: true)
        }
        return supportDir.appendingPathComponent("kPhotos.realm")
    }

    static var inMemoryKPhotos: Realm.Configuration {
        var config = Realm.Configuration()
        config.inMemoryIdentifier = "kPhotos.inMemory.\(UUID().uuidString)"
        config.objectTypes = [Photo.self, Album.self, SyncCheckpoint.self, Drive.self, SyncSettings.self, BackupItem.self, DeletionItem.self]
        return config
    }
}
