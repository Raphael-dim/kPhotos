/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

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
import Network

public enum NetworkKind: Equatable, Sendable {
    case offline
    case wifi
    case cellular
    case other          // ethernet, loopback, etc. — traité comme du wifi pour la sync.
}

public protocol NetworkReachable: AnyObject {
    /// Lecture instantanée — non bloquante. Si le monitor n'a pas encore reçu de
    /// snapshot (premières ms de l'app), retourne `.other` par défaut pour ne pas
    /// bloquer abusivement la sync au démarrage.
    func currentKind() -> NetworkKind

    /// Indique si la sync est autorisée par la politique réseau actuelle.
    func allowsSync(under policy: SyncNetworkPolicy) -> Bool
}

public final class NetworkReachabilityImpl: NetworkReachable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "app.kphotos.network", qos: .utility)
    private let lock = NSLock()
    private var cached: NetworkKind = .other

    public init() {
        self.monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let kind = Self.classify(path)
            self.lock.lock()
            self.cached = kind
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public func currentKind() -> NetworkKind {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    public func allowsSync(under policy: SyncNetworkPolicy) -> Bool {
        switch currentKind() {
        case .offline: return false
        case .wifi, .other: return policy.contains(.wifi)
        case .cellular: return policy.contains(.cellular)
        }
    }

    static func classify(_ path: NWPath) -> NetworkKind {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }
}
