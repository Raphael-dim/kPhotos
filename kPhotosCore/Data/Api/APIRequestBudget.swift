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

/// Only work that is about to start consumes quota. Canceled cells are removed
/// from the queue, and visible media takes precedence over background indexing.
actor APIRequestBudget {
    static let shared = APIRequestBudget(burstLimit: 12, backgroundWindowLimit: 40)
    private struct Waiter {
        let id: UUID
        let priority: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct Start { let time: TimeInterval; let isBackground: Bool }
    private var sleeper: Task<Void, Error>?
    private var waiting: [Waiter] = []
    private var worker: Task<Void, Never>?
    private let interval: TimeInterval
    private let burstLimit: Double
    private let windowLimit: Int
    private let window: TimeInterval
    private let backgroundWindowLimit: Int?
    private var tokens: Double
    private var updated = ProcessInfo.processInfo.systemUptime
    private var starts: [Start] = []

    init(
        interval: TimeInterval = 1.05,
        burstLimit: Int = 1,
        windowLimit: Int = 60,
        window: TimeInterval = 60.1,
        backgroundWindowLimit: Int? = nil
    ) {
        self.interval = interval
        self.burstLimit = Double(burstLimit)
        self.tokens = Double(burstLimit)
        self.windowLimit = windowLimit
        self.window = window
        self.backgroundWindowLimit = backgroundWindowLimit
    }

    func wait(priority: Int = 0) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting.append(Waiter(id: id, priority: priority, continuation: continuation))
                sleeper?.cancel()
                if worker == nil { worker = Task { await self.drain() } }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        sleeper?.cancel()
    }

    private func drain() async {
        while !waiting.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            tokens = min(burstLimit, tokens + (now - updated) / interval)
            updated = now
            starts.removeAll { now - $0.time >= window }
            guard let priority = waiting.map(\.priority).max() else { break }
            let tokenDelay = tokens >= 1 ? 0 : (1 - tokens) * interval
            let windowDelay = starts.count < windowLimit ? 0 : max(0, starts[0].time + window - now)
            let background = starts.filter(\.isBackground)
            let backgroundDelay: TimeInterval = if priority <= 0, let limit = backgroundWindowLimit, background.count >= limit {
                max(0, background[0].time + window - now)
            } else { 0 }
            let delay = max(tokenDelay, windowDelay, backgroundDelay)
            if delay > 0 {
                // New visible work wakes only the delay, preserving the global quota and all queued consumers.
                let wait = Task { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                sleeper = wait
                _ = await wait.result
                sleeper = nil
                continue // Re-evaluate quota and priorities after the suspension.
            }
            guard !waiting.isEmpty else { break }
            guard let index = waiting.firstIndex(where: { $0.priority == priority }) else { break }
            let next = waiting.remove(at: index)
            tokens -= 1
            starts.append(Start(time: now, isBackground: next.priority <= 0))
            next.continuation.resume()
        }
        worker = nil
    }
}
