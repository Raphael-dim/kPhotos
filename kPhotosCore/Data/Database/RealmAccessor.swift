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
import Security

public protocol RealmAccessor: AnyObject {
    /// Lecture sur le thread courant. Réservée aux lectures UI ; les écritures passent par `write`.
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
    private let initializationError: Error?

    private let writeQueue = DispatchQueue(
        label: "app.kphotos.realm.write",
        qos: .utility
    )

    public init(configuration: Realm.Configuration? = nil) {
        do {
            self.configuration = try configuration ?? .defaultKPhotos
            self.initializationError = nil
        } catch {
            // Never silently create an unencrypted database when Keychain is unavailable.
            self.configuration = Realm.Configuration()
            self.initializationError = error
        }
    }

    public func read<T>(_ block: (Realm) throws -> T) throws -> T {
        if let initializationError { throw initializationError }
        let realm = try Realm(configuration: configuration)
        realm.refresh()
        return try block(realm)
    }

    public func write(_ block: @escaping (Realm) throws -> Void) async throws {
        if let initializationError { throw initializationError }
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
        if let initializationError { throw initializationError }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            writeQueue.async {
                do {
                    let realm = try Realm(configuration: self.configuration)
                    let value = try realm.write {
                        try block(realm)
                    }
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public extension Realm.Configuration {
    static var defaultKPhotos: Realm.Configuration {
        get throws {
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
            // v9: additive library scope and resource verification state. Originals and cached metadata stay intact.
            // v10: additive capture-date provenance; old dates stay unconfirmed until refreshed.
            // v11: additive optional coordinates and location provenance.
            // v12: original-file metadata cache and revision.
            config.schemaVersion = 9
            config.objectTypes = [
                Photo.self,
                Album.self,
                SyncCheckpoint.self,
                Drive.self,
                SyncSettings.self,
                BackupItem.self,
                DeletionItem.self
            ]
            config.migrationBlock = { _, _ in
                // No-op : Realm gère automatiquement l'ajout de `BackupItem` / `DeletionItem`
                // (tables créées vides). Les éventuelles tables orphelines sont conservées
                // sur disque mais inaccessibles sans déclaration dans `objectTypes`.
            }
            config.fileURL = Self.kPhotosRealmURL()
            // Chiffrement at-rest : clé 64-byte stockée en Keychain (ThisDeviceOnly).
            // Sans ça, l'inventaire kDrive (fileIds, takenAt, paths) serait lisible
            // dès qu'un attaquant a accès au fichier `kPhotos.realm` post-unlock.
            // Keychain failure is surfaced by the accessor; never change the encryption mode silently.
            config.encryptionKey = try Self.kPhotosRealmEncryptionKey()
            try LegacyRealmEncryption.prepare(config)
            return config
        }
    }

    /// Charge la clé de chiffrement Realm depuis le Keychain, ou en génère
    /// une nouvelle si elle n'existe pas encore. 64 octets — taille exigée
    /// par Realm. Stockage `ThisDeviceOnly` → la clé ne suit pas les backups
    /// iCloud, et un device wipe = perte définitive (cohérent avec une cache
    /// reconstructible depuis kDrive).
    private static func kPhotosRealmEncryptionKey() throws -> Data {
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
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 64 else { throw AuthError.keychainFailure(status: errSecDecode) }
            return data
        }
        guard status == errSecItemNotFound else { throw AuthError.keychainFailure(status: status) }

        var bytes = [UInt8](repeating: 0, count: 64)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw AuthError.keychainFailure(status: randomStatus) }
        let newKey = Data(bytes)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = newKey
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another accessor generated the key concurrently: use its persisted key.
            return try kPhotosRealmEncryptionKey()
        }
        guard addStatus == errSecSuccess else { throw AuthError.keychainFailure(status: addStatus) }
        return newKey
    }

    /// Construit le chemin du fichier Realm en s'assurant que le dossier parent existe.
    /// `Library/Application Support/` n'est pas créé automatiquement dans la sandbox iOS.
    private static func kPhotosRealmURL() -> URL? {
        let fileManager = FileManager.default
        guard let supportDir = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        if !fileManager.fileExists(atPath: supportDir.path) {
            try? fileManager.createDirectory(
                at: supportDir,
                withIntermediateDirectories: true
            )
        }
        return supportDir.appendingPathComponent("kPhotos.realm")
    }

    static var inMemoryKPhotos: Realm.Configuration {
        var config = Realm.Configuration()
        config.inMemoryIdentifier = "kPhotos.inMemory.\(UUID().uuidString)"
        config.objectTypes = [
            Photo.self,
            Album.self,
            SyncCheckpoint.self,
            Drive.self,
            SyncSettings.self,
            BackupItem.self,
            DeletionItem.self
        ]
        return config
    }
}

/// Upgrade the old plaintext fallback without dropping the existing local library.
/// An encrypted file with an unknown key is never treated as a rebuildable cache.
enum LegacyRealmEncryption {
    private static let lock = NSLock()

    static func prepare(_ configuration: Realm.Configuration) throws {
        guard let original = configuration.fileURL, let key = configuration.encryptionKey,
              FileManager.default.fileExists(atPath: original.path) else { return }
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forReadingFrom: original)
        defer { try? handle.close() } // Read-only descriptor; the original is never truncated.
        try handle.seek(toOffset: 16)
        guard try handle.read(upToCount: 4) == Data("T-DB".utf8) else { return }

        let manager = FileManager.default
        let identifier = UUID().uuidString
        let parent = original.deletingLastPathComponent()
        let backup = parent.appendingPathComponent("DiagnosticBackups/LegacyPlaintext-" + identifier, isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        var protectedBackup = backup
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try protectedBackup.setResourceValues(resources)
        let preserved = backup.appendingPathComponent(original.lastPathComponent)
        try manager.copyItem(at: original, to: preserved)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: preserved.path)
        // Retain byte-for-byte evidence even if conversion or replacement later fails.
        guard try Data(contentsOf: preserved) == Data(contentsOf: original) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // .note may be a named pipe: copying it would block indefinitely.
        // Persistent records are in the Realm file; copy only regular sidecars.
        for suffix in [".lock", ".note"] {
            let source = URL(fileURLWithPath: original.path + suffix)
            if manager.fileExists(atPath: source.path),
               try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                try manager.copyItem(at: source, to: backup.appendingPathComponent(source.lastPathComponent))
            }
        }
        let staging = parent.appendingPathComponent(".realm-encryption-" + identifier, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) } // Only owned migration intermediates.
        let working = staging.appendingPathComponent("working.realm")
        let encrypted = staging.appendingPathComponent("encrypted.realm")
        try manager.copyItem(at: preserved, to: working)
        _ = try schemaVersionAtURL(working)

        try autoreleasepool {
            var sourceConfig = configuration
            sourceConfig.fileURL = working
            sourceConfig.encryptionKey = nil
            let source = try Realm(configuration: sourceConfig)
            let counts = source.schema.objectSchema.map { schema in
                (schema.className, source.dynamicObjects(schema.className).count)
            }
            try source.writeCopy(toFile: encrypted, encryptionKey: key)
            var verifiedConfig = configuration
            verifiedConfig.fileURL = encrypted
            let verified = try Realm(configuration: verifiedConfig)
            for (name, count) in counts {
                guard verified.dynamicObjects(name).count == count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        // Atomic replacement occurs only after the encrypted copy has been reopened.
        _ = try manager.replaceItemAt(original, withItemAt: encrypted)
    }
}
