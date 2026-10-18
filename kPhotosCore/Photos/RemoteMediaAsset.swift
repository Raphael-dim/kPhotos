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

import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Owns AVFoundation's weak resource delegate. Only URLSession handles the private signed HTTPS URL.
public final class RemoteMediaAsset {
    public let asset: AVURLAsset
    private let loader: RemoteMediaResourceLoader

    public init(url: URL, configuration: URLSessionConfiguration = .ephemeral, maximumBytes: Int? = 32 * 1024 * 1024) throws {
        guard let resourceURL = URL(string: "kphotos-media://original/asset.mov") else {
            throw PhotoAPIError.invalidResponse
        }
        self.loader = RemoteMediaResourceLoader(url: url, configuration: configuration, maximumBytes: maximumBytes)
        self.asset = AVURLAsset(url: resourceURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    public func cancel() { asset.cancelLoading(); loader.cancelAll() }
    deinit { cancel() }
}

private final class RemoteMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.kphotos.media-resource")
    private let url: URL
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int?
    private let lock = NSLock()
    private var requestedBytes = 0
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(url: URL, configuration: URLSessionConfiguration, maximumBytes: Int?) {
        self.url = url; self.configuration = configuration; self.maximumBytes = maximumBytes
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        let id = ObjectIdentifier(request)
        lock.lock()
        let task = Task {
            do {
                try await self.respond(to: request)
                request.finishLoading()
            } catch { request.finishLoading(with: error) }
            self.remove(id)
        }
        tasks[id] = task; lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        lock.lock(); let task = tasks.removeValue(forKey: ObjectIdentifier(request)); lock.unlock()
        task?.cancel()
    }

    private func remove(_ id: ObjectIdentifier) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func cancelAll() {
        lock.lock(); let active = Array(tasks.values); tasks.removeAll(); lock.unlock()
        for task in active {
            task.cancel()
        }
    }

    private func reserve(_ count: Int) throws {
        lock.lock(); defer { lock.unlock() }
        if let maximumBytes, count > maximumBytes - requestedBytes { throw PhotoAPIError.invalidResponse }
        requestedBytes += count
    }

    private func respond(to request: AVAssetResourceLoadingRequest) async throws {
        let dataRequest = request.dataRequest
        var offset = max(dataRequest?.requestedOffset ?? 0, dataRequest?.currentOffset ?? 0)
        var remaining = dataRequest.map { max(0, $0.requestedLength - Int(offset - $0.requestedOffset)) } ?? 2
        var length: Int64?
        repeat {
            try Task.checkCancellation()
            let count = min(max(remaining, 2), 262_144)
            try reserve(count)
            let reader = BoundedMediaRead(maximum: count, configuration: configuration)
            let bytes = try await reader.read(url: url, offset: offset)
            guard !bytes.isEmpty, let total = reader.resourceLength, total > 0 else { throw PhotoAPIError.invalidResponse }
            length = total
            if let info = request.contentInformationRequest {
                let mime = reader.mimeType ?? ""
                let type = UTType(mimeType: mime)
                info.contentType = type?.conforms(to: .movie) == true ? type?.identifier : UTType.quickTimeMovie.identifier
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            let useful = min(bytes.count, remaining)
            if useful > 0 { dataRequest?.respond(with: bytes.prefix(useful)); offset += Int64(useful); remaining -= useful }
            if dataRequest == nil { return }
        } while remaining > 0 && offset < (length ?? 0)
    }
}
