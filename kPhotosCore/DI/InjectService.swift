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

/// Shim DI local — même surface API que `InfomaniakDI` (`@InjectService`,
/// `SimpleResolver.sharedResolver`, `Factory`). À remplacer par le vrai
/// package quand son URL exacte sera confirmée. Le code consommateur n'aura
/// rien à changer.

public enum DIError: Error, CustomStringConvertible {
    case notRegistered(type: String)

    public var description: String {
        switch self {
        case .notRegistered(let type):
            return "No factory registered for type: \(type)"
        }
    }
}

public struct FactoryParameters {
    public init() {}
}

public final class Factory {
    public typealias Closure = (FactoryParameters?, Resolver) throws -> Any

    let type: Any.Type
    let closure: Closure

    public init(type: Any.Type, factoryClosure: @escaping Closure) {
        self.type = type
        self.closure = factoryClosure
    }
}

public protocol Resolver: AnyObject {
    func resolve<Service>(
        type: Service.Type,
        forCustomTypeIdentifier customIdentifier: String?,
        factoryParameters: FactoryParameters?,
        resolver: Resolver
    ) throws -> Service
}

public final class SimpleResolver: Resolver {
    public static let sharedResolver = SimpleResolver()

    private let lock = NSLock()
    private var factories: [String: Factory] = [:]
    private var singletons: [String: Any] = [:]

    public init() {}

    public func store(factory: Factory, forCustomTypeIdentifier customIdentifier: String? = nil) {
        let key = Self.key(for: factory.type, identifier: customIdentifier)
        lock.lock()
        defer { lock.unlock() }
        factories[key] = factory
    }

    public func resolve<Service>(
        type: Service.Type,
        forCustomTypeIdentifier customIdentifier: String?,
        factoryParameters: FactoryParameters?,
        resolver: Resolver
    ) throws -> Service {
        let key = Self.key(for: type, identifier: customIdentifier)

        lock.lock()
        if let cached = singletons[key] as? Service {
            lock.unlock()
            return cached
        }
        let factory = factories[key]
        lock.unlock()

        guard let factory else {
            throw DIError.notRegistered(type: String(describing: type))
        }

        let instance = try factory.closure(factoryParameters, resolver)
        guard let typed = instance as? Service else {
            throw DIError.notRegistered(type: String(describing: type))
        }

        lock.lock()
        singletons[key] = typed
        lock.unlock()
        return typed
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        factories.removeAll()
        singletons.removeAll()
    }

    private static func key(for type: Any.Type, identifier: String?) -> String {
        let typeName = String(describing: type)
        guard let identifier else { return typeName }
        return "\(typeName)::\(identifier)"
    }
}

@propertyWrapper
public struct InjectService<Service> {
    private let customIdentifier: String?

    public init(customTypeIdentifier: String? = nil) {
        self.customIdentifier = customTypeIdentifier
    }

    public var wrappedValue: Service {
        let resolver = SimpleResolver.sharedResolver
        do {
            return try resolver.resolve(
                type: Service.self,
                forCustomTypeIdentifier: customIdentifier,
                factoryParameters: nil,
                resolver: resolver
            )
        } catch {
            preconditionFailure("Missing DI registration for \(Service.self): \(error)")
        }
    }
}
