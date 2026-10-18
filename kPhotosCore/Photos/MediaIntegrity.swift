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

import CryptoKit
import Foundation
import kPhotosResources

public enum BackupSafetyError: Error, LocalizedError {
    case incomplete
    case integrity
    case tooLarge
    case busy
    public var errorDescription: String? {
        switch self {
        case .incomplete: L10n.BackupSafety.incomplete
        case .integrity: L10n.BackupSafety.integrity
        case .tooLarge: L10n.BackupSafety.tooLarge
        case .busy: L10n.BackupSafety.busy
        }
    }
}

public enum MediaIntegrity {
    public static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func token(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(18).map { String(format: "%02x", $0) }.joined()
    }
}
