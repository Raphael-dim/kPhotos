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

@testable import kPhotosCore
import RealmSwift
import XCTest

/// Tests des modèles Realm (instanciés non-managés) et de leurs snapshots
/// thread-safe. On vérifie surtout les propriétés calculées enum↔raw et le
/// passage entité → snapshot (cf. AGENTS.md §21 Realm thread-safety).
final class PhotoModelTests: XCTestCase {
    func testSyncStatus_roundTripsThroughRawValue() throws {
        let photo = Photo()
        photo.syncStatus = .uploading
        XCTAssertEqual(photo.syncStatusRaw, "uploading")
        XCTAssertEqual(photo.syncStatus, .uploading)
    }

    func testSyncStatus_invalidRaw_mapsToError() throws {
        let photo = Photo()
        photo.syncStatusRaw = "garbage"
        XCTAssertEqual(photo.syncStatus, .error)
    }

    func testSnapshot_fromEntity_copiesFields() throws {
        let photo = Photo()
        photo.fileId = "F1"
        photo.driveId = 9
        photo.localIdentifier = "L1"
        photo.name = "p.jpg"
        photo.isVideo = true
        photo.size = 4096
        photo.isFavorite = true
        photo.syncStatus = .synced

        let snapshot = PhotoSnapshot(photo)
        XCTAssertEqual(snapshot.id, "F1")
        XCTAssertEqual(snapshot.fileId, "F1")
        XCTAssertEqual(snapshot.driveId, 9)
        XCTAssertEqual(snapshot.localIdentifier, "L1")
        XCTAssertEqual(snapshot.size, 4096)
        XCTAssertTrue(snapshot.isVideo)
        XCTAssertTrue(snapshot.isFavorite)
        XCTAssertEqual(snapshot.syncStatus, .synced)
        XCTAssertTrue(snapshot.albumIds.isEmpty)
    }

    func testMakePhoto_fromSnapshot_copiesAllFields() throws {
        var snapshot = PhotoSnapshot(
            id: "F1",
            driveId: 5,
            localIdentifier: "L1",
            name: "x.jpg",
            takenAt: Date(timeIntervalSince1970: 1000),
            uploadedAt: Date(timeIntervalSince1970: 2000),
            mimeType: "image/jpeg",
            size: 123,
            isVideo: false,
            duration: 0,
            albumIds: ["a", "b"],
            syncStatus: .synced,
            isFavorite: true
        )
        snapshot.resourceRevisions = ["original": "révision-\"1\""]
        let photo = try PhotoManagerImpl.makePhoto(from: snapshot)
        XCTAssertEqual(PhotoSnapshot(photo).resourceRevisions, snapshot.resourceRevisions)
        XCTAssertEqual(photo.fileId, "F1")
        XCTAssertEqual(photo.driveId, 5)
        XCTAssertEqual(photo.localIdentifier, "L1")
        XCTAssertEqual(photo.name, "x.jpg")
        XCTAssertEqual(photo.size, 123)
        XCTAssertEqual(photo.syncStatus, .synced)
        XCTAssertTrue(photo.isFavorite)
        // Round-trip via snapshot pour vérifier les albumIds sans toucher au type Realm.
        XCTAssertEqual(PhotoSnapshot(photo).albumIds, ["a", "b"])
    }
}

final class BackupItemModelTests: XCTestCase {
    func testState_roundTripsThroughRawValue() throws {
        let item = BackupItem()
        item.state = .failedTransient
        XCTAssertEqual(item.stateRaw, "failedTransient")
        XCTAssertEqual(item.state, .failedTransient)
    }

    func testState_invalidRaw_fallsBackToQueued() throws {
        let item = BackupItem()
        item.stateRaw = "???"
        XCTAssertEqual(item.state, .queued)
    }

    func testSnapshot_fromEntity_copiesFields() throws {
        let item = BackupItem()
        item.localIdentifier = "L1"
        item.state = .uploading
        item.clientToken = "tok"
        item.attemptCount = 2
        item.isVideo = true
        item.lastErrorReason = "boom"

        let snapshot = BackupItemSnapshot(item)
        XCTAssertEqual(snapshot.localIdentifier, "L1")
        XCTAssertEqual(snapshot.state, .uploading)
        XCTAssertEqual(snapshot.clientToken, "tok")
        XCTAssertEqual(snapshot.attemptCount, 2)
        XCTAssertTrue(snapshot.isVideo)
        XCTAssertEqual(snapshot.lastErrorReason, "boom")
    }
}

final class DeletionItemModelTests: XCTestCase {
    func testState_roundTripsThroughRawValue() throws {
        let item = DeletionItem()
        item.state = .deleting
        XCTAssertEqual(item.stateRaw, "deleting")
        XCTAssertEqual(item.state, .deleting)
    }

    func testState_invalidRaw_fallsBackToQueued() throws {
        let item = DeletionItem()
        item.stateRaw = "nope"
        XCTAssertEqual(item.state, .queued)
    }

    func testSnapshot_fromEntity_copiesFields() throws {
        let item = DeletionItem()
        item.fileId = "F1"
        item.driveId = 7
        item.localIdentifier = "L1"
        item.state = .failedPermanent
        item.lastErrorReason = "403"

        let snapshot = DeletionItemSnapshot(item)
        XCTAssertEqual(snapshot.fileId, "F1")
        XCTAssertEqual(snapshot.driveId, 7)
        XCTAssertEqual(snapshot.localIdentifier, "L1")
        XCTAssertEqual(snapshot.state, .failedPermanent)
        XCTAssertEqual(snapshot.lastErrorReason, "403")
    }
}

final class DriveModelTests: XCTestCase {
    func testSnapshot_fromEntity_copiesFields() throws {
        let drive = Drive()
        drive.id = 3
        drive.name = "Perso"
        drive.usedSize = 500
        drive.privateSpaceId = "ps-1"
        drive.rootFolderId = "root-1"
        drive.isSelected = true

        let snapshot = DriveSnapshot(drive)
        XCTAssertEqual(snapshot.id, 3)
        XCTAssertEqual(snapshot.name, "Perso")
        XCTAssertEqual(snapshot.usedSize, 500)
        XCTAssertEqual(snapshot.privateSpaceId, "ps-1")
        XCTAssertEqual(snapshot.rootFolderId, "root-1")
        XCTAssertTrue(snapshot.isSelected)
    }
}

final class AlbumModelTests: XCTestCase {
    func testSnapshot_fromEntity_copiesFields() throws {
        let album = Album()
        album.id = "cat-1"
        album.driveId = 4
        album.name = "Vacances"
        album.coverPhotoId = "F9"
        album.photoCount = 12
        album.isShared = true

        let snapshot = AlbumSnapshot(album)
        XCTAssertEqual(snapshot.id, "cat-1")
        XCTAssertEqual(snapshot.driveId, 4)
        XCTAssertEqual(snapshot.name, "Vacances")
        XCTAssertEqual(snapshot.coverPhotoId, "F9")
        XCTAssertEqual(snapshot.photoCount, 12)
        XCTAssertTrue(snapshot.isShared)
    }
}

final class SyncSettingsModelTests: XCTestCase {
    func testNetworkPolicy_computedProperty_packsAndUnpacks() throws {
        let entity = SyncSettings()
        entity.networkPolicy = .unrestricted
        XCTAssertEqual(entity.networkPolicyRaw, SyncNetworkPolicy.unrestricted.rawValue)
        XCTAssertEqual(entity.networkPolicy, .unrestricted)
    }

    func testMediaFilter_computedProperty_packsAndUnpacks() throws {
        let entity = SyncSettings()
        entity.mediaFilter = .photosOnly
        XCTAssertEqual(entity.mediaFilterRaw, SyncMediaFilter.photosOnly.rawValue)
        XCTAssertEqual(entity.mediaFilter, .photosOnly)
    }

    func testSnapshot_fromEntity_trimsRootFolderName() throws {
        let entity = SyncSettings()
        entity.rootFolderName = "  Mes Photos  "
        XCTAssertEqual(SyncSettingsSnapshot(entity).rootFolderName, "Mes Photos")
    }

    func testSnapshot_fromEntity_blankRootFolder_fallsBackToDefault() throws {
        let entity = SyncSettings()
        entity.rootFolderName = "   "
        XCTAssertEqual(
            SyncSettingsSnapshot(entity).rootFolderName,
            SyncSettingsSnapshot.defaultRootFolderName
        )
    }

    func testSnapshot_fromEntity_copiesToggleAndPolicy() throws {
        let entity = SyncSettings()
        entity.isAutoSyncEnabled = true
        entity.networkPolicy = .unrestricted
        entity.mediaFilter = .videosOnly

        let snapshot = SyncSettingsSnapshot(entity)
        XCTAssertTrue(snapshot.isAutoSyncEnabled)
        XCTAssertEqual(snapshot.networkPolicy, .unrestricted)
        XCTAssertEqual(snapshot.mediaFilter, .videosOnly)
    }
}

final class LegacyRealmEncryptionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPlaintextLibraryIsPreservedAndEncrypted() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var config = Realm.Configuration(
            fileURL: folder.appendingPathComponent("library.realm"),
            schemaVersion: 10,
            objectTypes: [Drive.self, Photo.self, Album.self, BackupItem.self, SyncSettings.self]
        )
        try autoreleasepool {
            let realm = try Realm(configuration: config)
            let drive = Drive()
            drive.id = 42; drive.name = "Library"; drive.isSelected = true; drive.rootFolderId = "57997"
            let photo = Photo()
            photo.fileId = "old-photo"; photo.isFavorite = true; photo.name = "original.heic"
            let album = Album()
            album.id = "old-album"; album.name = "Trip"
            let pending = BackupItem()
            pending.localIdentifier = "local-original"; pending.state = .failedTransient
            let settings = SyncSettings()
            settings.rootFolderName = "Photos & Vidéos"
            try realm.write { realm.add([drive, photo, album, pending, settings]) }
        }
        let original = try Data(contentsOf: XCTUnwrap(config.fileURL))
        config.encryptionKey = Data(repeating: 17, count: 64)
        try LegacyRealmEncryption.prepare(config)
        let backups = try FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("DiagnosticBackups"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("library.realm")), original)
        try autoreleasepool {
            let realm = try Realm(configuration: config)
            XCTAssertEqual(realm.objects(Drive.self).first?.rootFolderId, "57997")
            XCTAssertTrue(realm.objects(Drive.self).first?.isSelected == true)
            XCTAssertTrue(realm.objects(Photo.self).first?.isFavorite == true)
            XCTAssertEqual(realm.objects(Photo.self).first?.name, "original.heic")
            XCTAssertEqual(realm.objects(Album.self).first?.name, "Trip")
            XCTAssertEqual(realm.objects(BackupItem.self).first?.state, .failedTransient)
            XCTAssertEqual(realm.objects(SyncSettings.self).first?.rootFolderName, "Photos & Vidéos")
        }
        let encrypted = try Data(contentsOf: XCTUnwrap(config.fileURL))
        try LegacyRealmEncryption.prepare(config)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(config.fileURL)), encrypted)
    }

    func testUnknownEncryptedKeyNeverReplacesTheDatabase() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var config = Realm.Configuration(
            fileURL: folder.appendingPathComponent("library.realm"),
            encryptionKey: Data(repeating: 18, count: 64),
            objectTypes: [Drive.self]
        )
        try autoreleasepool { _ = try Realm(configuration: config) }
        let original = try Data(contentsOf: XCTUnwrap(config.fileURL))
        config.encryptionKey = Data(repeating: 19, count: 64)
        try LegacyRealmEncryption.prepare(config)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(config.fileURL)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DiagnosticBackups").path))
    }

    func testInvalidPlaintextHeaderIsBackedUpWithoutReplacement() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var bytes = Data(repeating: 0, count: 64)
        bytes.replaceSubrange(16 ..< 20, with: Data("T-DB".utf8))
        bytes[20] = 255; bytes[21] = 255 // Invalid Realm file format, not a valid empty header.
        let file = folder.appendingPathComponent("library.realm")
        try bytes.write(to: file)
        let config = Realm.Configuration(fileURL: file, encryptionKey: Data(repeating: 20, count: 64), objectTypes: [Drive.self])
        XCTAssertThrowsError(try LegacyRealmEncryption.prepare(config))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let backups = try FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("DiagnosticBackups"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("library.realm")), bytes)
    }
}
