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

public protocol CloudThumbnailFetching: AnyObject {
    func data(driveId: Int, fileId: String, revision: String, priority: Int) async throws -> Data
}

/// Coalesce identical requests, cancel network work when its final consumer leaves.
public actor ThumbnailRequestBroker: CloudThumbnailFetching {
    private struct Flight {
        let id: UUID
        let task: Task<Data, Error>
        var consumers: Set<UUID>
    }

    private let api: PhotoApiFetching
    private var flights: [String: Flight] = [:]
    public init(api: PhotoApiFetching) { self.api = api }

    public func data(driveId: Int, fileId: String, revision: String, priority: Int) async throws -> Data {
        try Task.checkCancellation()
        let key = "\(driveId):\(fileId):\(revision)"
        let consumer = UUID()
        var flight: Flight
        if let existing = flights[key] {
            flight = existing
        } else {
            flight = Flight(
                id: UUID(),
                task: Task {
                    try await api.thumbnailData(driveId: driveId, fileId: fileId, revision: revision, priority: priority)
                },
                consumers: []
            )
        }
        flight.consumers.insert(consumer)
        flights[key] = flight
        return try await withTaskCancellationHandler {
            do {
                let data = try await flight.task.value
                release(key: key, consumer: consumer, flightId: flight.id)
                try Task.checkCancellation()
                return data
            } catch {
                release(key: key, consumer: consumer, flightId: flight.id)
                throw error
            }
        } onCancel: { Task { await self.release(key: key, consumer: consumer, flightId: flight.id) }
        }
    }

    private func release(key: String, consumer: UUID, flightId: UUID) {
        guard var flight = flights[key], flight.id == flightId else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty { flight.task.cancel(); flights[key] = nil } else { flights[key] = flight }
    }
}
