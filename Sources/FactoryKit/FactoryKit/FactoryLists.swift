//
// FactoryLists.swift
//
// GitHub Repo and Documentation: https://github.com/hmlongco/Factory
//
// Copyright © 2022-2025 Michael Long. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

import Foundation

public nonisolated struct FactoryListItem<T> {
    internal let key: FactoryKey
    internal let factory: VoidFactoryType<T>
    internal var scope: Scope?

    public init(key: StaticString, _ factory: @escaping VoidFactoryType<T>) {
        self.key = FactoryKey(type: T.self, key: key)
        self.factory = factory
        self.scope = nil
    }

    @discardableResult
    public func scope(_ scope: Scope) -> Self {
        var copy = self
        copy.scope = scope
        return copy
    }

    public var cached: Self {
        scope(.cached)
    }

    public var graph: Self {
        scope(.graph)
    }

    public var shared: Self {
        scope(.shared)
    }

    public var singleton: Self {
        scope(.singleton)
    }

    public var unique: Self {
        scope(.unique)
    }
}

public nonisolated struct FactoryList<T> {
    internal let container: ManagedContainer
    internal let key: FactoryKey
    internal let defaultScope: Scope?

    internal init(_ container: ManagedContainer, key: StaticString = #function, scope: Scope? = nil) {
        self.container = container
        self.key = FactoryKey(type: T.self, key: key)
        self.defaultScope = scope
    }

    public func callAsFunction() -> FactoryListSnapshot<T> {
        resolve()
    }

    public func resolve() -> FactoryListSnapshot<T> {
        container.manager.lock.withLock {
            container.unsafeCheckAutoRegistration()
            let entries = container.manager.lists[key]?.items.compactMap { $0 as? TypedFactoryListEntry<T> } ?? []
            return FactoryListSnapshot(entries: entries)
        }
    }

    @discardableResult
    public func append<C: SharedContainer>(_ keyPath: KeyPath<C, Factory<T>>) -> Self {
        let target = (container as? C) ?? C.shared
        let factory = target[keyPath: keyPath]
        let entryKey = FactoryListItemKey.factory(container: C.self, key: factory.registration.key)
        let entry = TypedFactoryListEntry(key: entryKey) {
            target[keyPath: keyPath].resolve()
        }
        append(entry)
        return self
    }

    @discardableResult
    public func append(_ item: FactoryListItem<T>) -> Self {
        let entryKey = FactoryListItemKey.inline(key: item.key)
        let scope = item.scope ?? defaultScope ?? .unique
        let scopeKey = inlineScopeKey(for: item)
        let entry = TypedFactoryListEntry(key: entryKey) {
            resolveInlineItem(key: scopeKey, scope: scope, factory: item.factory)
        } reset: { options in
            switch options {
            case .all, .registration, .scope:
                let cache = (scope as? InternalScopeCaching)?.cache ?? container.manager.cache
                cache.removeExactValue(forKey: scopeKey)
            case .context, .none:
                break
            }
        }
        append(entry) {
            if scope === Scope.graph {
                container.manager.state.hasGraphScope = true
            }
        }
        return self
    }

    @discardableResult
    public func reset(_ options: FactoryResetOptions = .all) -> Self {
        guard options != .none else {
            return self
        }
        container.manager.lock.withLock {
            switch options {
            case .all, .registration:
                let entries = container.manager.lists.removeValue(forKey: key)?.items ?? []
                entries.forEach { $0.reset(options) }
            case .scope:
                let entries = container.manager.lists[key]?.items ?? []
                entries.forEach { $0.reset(options) }
            case .context, .none:
                break
            }
        }
        snapshotFactory.reset(options)
        return self
    }

    internal func append(_ entry: TypedFactoryListEntry<T>, configure: () -> Void = {}) {
        container.manager.lock.withLock {
            container.unsafeCheckAutoRegistration()
            var options = container.manager.lists[key] ?? FactoryListOptions()
            guard options.keys.insert(entry.key).inserted else {
                return
            }
            options.items.append(entry)
            container.manager.lists[key] = options
            configure()
        }
    }

    internal func inlineScopeKey(for item: FactoryListItem<T>) -> FactoryKey {
        FactoryKey(type: FactoryListInlineScopeNamespace<T>.self, key: item.key.key)
            .parameterized(FactoryListInlineScopeKey(list: key, item: item.key))
    }

    internal func resolveInlineItem(
        key: FactoryKey,
        scope: Scope,
        factory: @escaping VoidFactoryType<T>
    ) -> T {
        let manager = container.manager
        manager.lock.lock()
        if manager.state.autoRegistrationCheckNeeded {
            container.unsafeCheckAutoRegistration()
        }
        #if DEBUG
        let globalLockRequired = manager.state.hasGraphScope || scope === Scope.graph || globalTraceFlag || globalCircularDependencyTesting
        #else
        let globalLockRequired = manager.state.hasGraphScope || scope === Scope.graph
        #endif
        manager.lock.unlock()

        if globalLockRequired {
            globalRecursiveLock.lock()
        }

        #if DEBUG
        if globalCircularDependencyTesting, globalCircularDependencyKeys.insert(key).0 == false {
            let message = "FACTORY: Circular dependency on \(type(of: container)).\(key.key)"
            resetAndTriggerFatalError(message, #file, #line)
        }
        #endif

        Scope.graph.enter()
        let instance = scope.resolve(using: manager.cache, key: key, ttl: nil, factory: factory).0
        Scope.graph.leave()

        #if DEBUG
        if globalCircularDependencyTesting {
            globalCircularDependencyKeys.remove(key)
        }
        #endif

        if globalLockRequired {
            globalRecursiveLock.unlock()
        }

        return instance
    }
}

extension FactoryList {
    internal var snapshotFactory: Factory<FactoryListSnapshot<T>> {
        Factory(container, key: key.key) {
            resolve()
        }
    }
}

public nonisolated struct FactoryListSnapshot<T>: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = T

    private let entries: [TypedFactoryListEntry<T>]

    internal init(entries: [TypedFactoryListEntry<T>]) {
        self.entries = entries
    }

    public var startIndex: Int {
        entries.startIndex
    }

    public var endIndex: Int {
        entries.endIndex
    }

    public subscript(position: Int) -> T {
        entries[position].resolve()
    }
}

extension ManagedContainer {
    public func list<T>(key: StaticString = #function, scope: Scope? = nil) -> FactoryList<T> {
        FactoryList(self, key: key, scope: scope)
    }
}

internal struct FactoryListOptions {
    var keys: Set<FactoryListItemKey> = []
    var items: [AnyFactoryListEntry] = []
}

internal protocol AnyFactoryListEntry {
    var key: FactoryListItemKey { get }
    var reset: (FactoryResetOptions) -> Void { get }
}

internal struct TypedFactoryListEntry<T>: AnyFactoryListEntry {
    let key: FactoryListItemKey
    let resolve: () -> T
    var reset: (FactoryResetOptions) -> Void = { _ in }
}

internal enum FactoryListItemKey: Hashable, CustomStringConvertible {
    case factory(container: ObjectIdentifier, key: FactoryKey)
    case inline(key: FactoryKey)

    static func factory<C>(container: C.Type, key: FactoryKey) -> Self {
        .factory(container: ObjectIdentifier(container), key: key)
    }

    var description: String {
        switch self {
        case let .factory(container, key):
            return "factory(\(container), \(key.key))"
        case let .inline(key):
            return "inline(\(key.key))"
        }
    }
}

private enum FactoryListInlineScopeNamespace<T> {}

private struct FactoryListInlineScopeKey: Hashable {
    let list: FactoryKey
    let item: FactoryKey
}
