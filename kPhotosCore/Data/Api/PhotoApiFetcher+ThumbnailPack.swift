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

public extension PhotoApiFetcher {
    func thumbnailPackData(driveId: Int, reference: ThumbnailPackReference) async throws -> Data {
        let file = try await fileInfo(driveId: driveId, fileId: reference.fileId)
        guard file.parentId == reference.folderId, file.name.hasPrefix("thumbs-"), file.name.hasSuffix(".sqlite"),
              file.size > 0, file.size <= 16 * 1024 * 1024 else { throw PhotoAPIError.invalidResponse }
        let url = try await signedOriginalURL(driveId: driveId, fileId: reference.fileId, priority: 1)
        let bytes = try await BoundedMediaRead(maximum: 16 * 1024 * 1024).read(url: url)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == reference.sha256 else {
            throw PhotoAPIError.invalidResponse
        }
        return bytes
    }
}
