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
import SQLite3

public struct ThumbnailPackReference: Codable, Equatable, Sendable {
    public let fileId: String
    public let folderId: String
    public let sha256: String
    public init(fileId: String, folderId: String, sha256: String) {
        self.fileId = fileId; self.folderId = folderId; self.sha256 = sha256
    }
}

/// Immutable, app-generated thumbnail database. Read-only fixed SQL; never execute input SQL or load extensions.
public enum ThumbnailPack {
    private static let tableSQL =
        "CREATE TABLE thumbnails(id TEXT NOT NULL, revision TEXT NOT NULL,jpeg BLOB NOT NULL,PRIMARY KEY(id,revision))"
    public static func imageData(at url: URL, fileId: String, revision: String) throws -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); throw PhotoAPIError.invalidResponse
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA trusted_schema=OFF", nil, nil, nil)
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT sql FROM sqlite_schema WHERE name='thumbnails' AND type='table'",
            -1,
            &schema,
            nil
        ) ==
            SQLITE_OK else {
            throw PhotoAPIError.invalidResponse
        }
        defer { sqlite3_finalize(schema) }
        guard sqlite3_step(schema) == SQLITE_ROW, let sql = sqlite3_column_text(schema, 0),
              String(cString: sql) == tableSQL else { throw PhotoAPIError.invalidResponse }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT jpeg FROM thumbnails WHERE id=? AND revision=?", -1, &stmt, nil) == SQLITE_OK else {
            throw PhotoAPIError.invalidResponse
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, fileId, -1, transient); sqlite3_bind_text(stmt, 2, revision, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let size = Int(sqlite3_column_bytes(stmt, 0))
        guard size > 0, size <= 1024 * 1024, let blob = sqlite3_column_blob(stmt, 0) else { throw PhotoAPIError.invalidResponse }
        return Data(bytes: blob, count: size)
    }

    public struct Image: Sendable {
        public let fileId: String
        public let revision: String
        public let data: Data

        public init(fileId: String, revision: String, data: Data) {
            self.fileId = fileId
            self.revision = revision
            self.data = data
        }
    }

    public static func create(at url: URL, images: [Image]) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PhotoAPIError.invalidResponse }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) ==
            SQLITE_OK else {
            sqlite3_close(db); throw PhotoAPIError.invalidResponse
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(
            db,
            tableSQL + "; BEGIN IMMEDIATE",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw PhotoAPIError.invalidResponse }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO thumbnails VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK else {
            throw PhotoAPIError.invalidResponse
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for image in images {
            let id = image.fileId
            let revision = image.revision
            let jpeg = image.data
            guard !jpeg.isEmpty, jpeg.count <= 1024 * 1024 else { throw PhotoAPIError.invalidResponse }
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, transient); sqlite3_bind_text(stmt, 2, revision, -1, transient)
            _ = jpeg.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(jpeg.count), transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw PhotoAPIError.invalidResponse }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw PhotoAPIError.invalidResponse }
    }
}
