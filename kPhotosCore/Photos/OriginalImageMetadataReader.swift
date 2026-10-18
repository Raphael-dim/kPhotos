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

/// Progressive bounded reads; a partial parse is never evidence that the complete original has no GPS.
struct OriginalImageMetadataReader {
    let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }

    func read(url: URL) async throws -> EmbeddedMediaMetadata {
        var last: EmbeddedMediaMetadata?
        for maximum in [65536, 262_144, 1_048_576, 4_194_304, 16_777_216, 33_554_432] {
            try Task.checkCancellation()
            let reader = BoundedMediaRead(maximum: maximum, configuration: configuration)
            let data: Data
            do { data = try await reader.read(url: url) } catch PhotoAPIError.invalidResponse {
                // A small server without Range may accept the next bounded whole-file request.
                continue
            }
            let complete = reader.resourceLength == Int64(data.count) || Self.hasCompleteJPEGHeader(data)
            if var metadata = EmbeddedMediaMetadata.image(data: data, complete: reader.resourceLength == Int64(data.count)) {
                metadata.partialRead = !complete
                last = metadata
                if complete { return metadata }
            }
        }
        if let last { return last }
        throw PhotoAPIError.invalidResponse
    }

    static func hasCompleteJPEGHeader(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        var offset = 2
        while offset + 1 < bytes.count {
            guard bytes[offset] == 0xFF else { return false }
            while offset < bytes.count, bytes[offset] == 0xFF {
                offset += 1
            }
            guard offset < bytes.count else { return false }
            let marker = bytes[offset]; offset += 1
            if marker == 0xDA || marker == 0xD9 { return true }
            if marker == 0x01 || (0xD0 ... 0xD7).contains(marker) { continue }
            guard offset + 1 < bytes.count else { return false }
            let size = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard size >= 2, size <= bytes.count - offset else { return false }
            offset += size
        }
        return false
    }
}
