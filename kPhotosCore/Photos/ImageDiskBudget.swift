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

public enum ImageDiskBudget {
    private static let queue = DispatchQueue(label: "app.kphotos.image-cache", qos: .utility)
    private static var writes = 0
    private static var lastTrim: [URL: Date] = [:]

    public static func scheduleTrim(directory: URL, limit: Int) {
        queue.async { trim(directory: directory, limit: limit) }
    }

    public static func touch(_ url: URL) {
        queue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
    }

    public static func store(_ data: Data, at url: URL, limit: Int) {
        queue.async {
            let directory = url.deletingLastPathComponent()
            let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?
                .int64Value
            // Cache is expendable: leave at least 128 MiB free rather than fill the phone.
            if let free, free - Int64(data.count) < 128 * 1024 * 1024 { return }
            try? data.write(to: url, options: .atomic)
            writes += 1
            if writes.isMultiple(of: 32) || Date().timeIntervalSince(lastTrim[directory] ?? .distantPast) > 30 {
                trim(directory: directory, limit: limit)
                lastTrim[directory] = Date()
            }
        }
    }

    public static func waitForWrites() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private struct Entry {
        let url: URL
        let size: Int
        let modified: Date
    }

    public static func trim(directory: URL, limit: Int) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries = files.compactMap { url -> Entry? in
            guard let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true else { return nil }
            return Entry(url: url, size: info.fileSize ?? 0, modified: info.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modified < $1.modified }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > limit {
            do { try FileManager.default.removeItem(at: entry.url); total -= entry.size } catch { continue }
        }
    }
}
