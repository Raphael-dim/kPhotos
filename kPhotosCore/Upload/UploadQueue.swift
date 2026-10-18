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

import Combine
import Foundation

/// État runtime d'un upload (pas persisté — perdu au redémarrage de l'app, c'est OK :
/// au prochain run on relit Realm et on requalifie les locaux comme `localOnly`).
public enum UploadState: Equatable, Sendable {
    case pending
    case uploading(fraction: Double?)
    case completed
    case failed(reason: String)
}

public protocol UploadQueueReading: AnyObject {
    /// État courant indexé par `PHAsset.localIdentifier`.
    var statesPublisher: AnyPublisher<[String: UploadState], Never> { get }
    var currentStates: [String: UploadState] { get }
}

public protocol UploadQueueWriting: AnyObject {
    func mark(localIdentifier: String, state: UploadState)
    func clearCompleted()
}

public typealias UploadQueueing = UploadQueueReading & UploadQueueWriting

/// File observable des uploads en cours. Thread-safe (lock interne).
/// Consommée :
/// - par `TimelineViewModel` pour superposer l'indicateur sur les tuiles
/// - par `PhotoSyncEngine` qui pousse les transitions à chaque étape de l'upload
public final class UploadQueueImpl: UploadQueueing {
    private let lock = NSLock()
    private var states: [String: UploadState] = [:]
    private let subject = CurrentValueSubject<[String: UploadState], Never>([:])

    public init() {}

    public var statesPublisher: AnyPublisher<[String: UploadState], Never> {
        subject.eraseToAnyPublisher()
    }

    public var currentStates: [String: UploadState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    public func mark(localIdentifier: String, state: UploadState) {
        guard !localIdentifier.isEmpty else { return }
        lock.lock()
        states[localIdentifier] = state
        let snapshot = states
        lock.unlock()
        subject.send(snapshot)
    }

    /// Nettoie les `completed` et `failed` — appelé en fin de session de sync,
    /// pour qu'un asset terminé bascule sur l'état persistant `synced` au prochain
    /// rebuild de la galerie (qui lit Realm) sans clignoter par cet état runtime.
    public func clearCompleted() {
        lock.lock()
        states = states.filter { _, state in
            switch state {
            case .completed, .failed: return false
            case .pending, .uploading: return true
            }
        }
        let snapshot = states
        lock.unlock()
        subject.send(snapshot)
    }
}
