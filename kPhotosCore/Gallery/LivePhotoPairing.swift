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

/// A Live Photo is one gallery item backed by two untouched originals.
/// Ambiguous identifiers stay as separate items; filenames never establish a pairing.
public struct LivePhotoPairing: Sendable {
    public let motionByStillId: [String: PhotoSnapshot]
    public let motionFileIds: Set<String>

    public init(photos: [PhotoSnapshot]) {
        var stills: [String: [PhotoSnapshot]] = [:]
        var motions: [String: [PhotoSnapshot]] = [:]
        for photo in photos where photo.isAvailable && !photo.liveContentIdentifier.isEmpty {
            let key = "\(photo.driveId):\(photo.libraryRootId):\(photo.liveContentIdentifier)"
            if photo.isVideo {
                let duration = photo.embeddedMetadata?.duration ?? photo.duration
                if duration > 0, duration <= 5 { motions[key, default: []].append(photo) }
            } else {
                stills[key, default: []].append(photo)
            }
        }
        var matches: [String: PhotoSnapshot] = [:]
        var hidden = Set<String>()
        for (key, images) in stills where images.count == 1 {
            guard let videos = motions[key], videos.count == 1 else { continue }
            matches[images[0].fileId] = videos[0]
            hidden.insert(videos[0].fileId)
        }
        self.motionByStillId = matches
        self.motionFileIds = hidden
    }

    public func attachMotion(to still: PhotoSnapshot) -> PhotoSnapshot {
        var result = still
        if let motion = motionByStillId[still.fileId] {
            result.liveMotionFileId = motion.fileId
            result.liveMotionName = motion.name
        }
        return result
    }
}
