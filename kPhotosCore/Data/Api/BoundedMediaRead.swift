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

/// A server ignoring Range cannot make us download a complete large original.
final class BoundedMediaRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximum: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var canceled = false
    private var bytes = Data()
    private(set) var resourceLength: Int64?
    private(set) var mimeType: String?
    private var offset: Int64 = 0

    init(maximum: Int, configuration: URLSessionConfiguration = .ephemeral) {
        self.maximum = maximum
        self.configuration = configuration
    }

    func read(url: URL, offset: Int64 = 0) async throws -> Data {
        guard offset >= 0, maximum > 0, offset <= Int64.max - Int64(maximum) else { throw PhotoAPIError.invalidResponse }
        self.offset = offset
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !canceled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("bytes=\(offset)-\(offset + Int64(maximum) - 1)", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.timeoutInterval = 30
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel()
        }
    }

    private func cancel() {
        lock.lock(); canceled = true; let task = task; lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (
                  response.statusCode == 206
                      && response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true
              )
              || (
                  response.statusCode == 200 && offset == 0 && response.expectedContentLength >= 0
                      && response.expectedContentLength <= maximum
              ),
              response.expectedContentLength <= maximum else {
            completionHandler(.cancel)
            finish(.failure(PhotoAPIError.invalidResponse))
            return
        }
        mimeType = response.mimeType
        if response.statusCode == 200 {
            resourceLength = response.expectedContentLength
        } else if let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last {
            resourceLength = Int64(total)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximum - bytes.count else {
            dataTask.cancel(); finish(.failure(PhotoAPIError.invalidResponse)); return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(bytes)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }
}
