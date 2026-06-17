# FactoryList Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `FactoryList<T>` so multiple modules can explicitly contribute ordered service factories into a container-managed list and consumers can resolve a snapshot collection.

**Architecture:** `FactoryList<T>` is a transient container-bound registration/resolution entry point. Durable list entries live in `ContainerManager`, while `FactoryListSnapshot<T>` is an immutable `RandomAccessCollection` that resolves each item on access. Inline items use the list default scope unless they define their own scope; key-path items keep their own factory scope.

**Tech Stack:** Swift 6.1 package, FactoryKit, XCTest, Swift Testing-compatible container semantics, DocC Markdown.

---

## Git Policy

This repository should not commit implementation or documentation changes unless the user explicitly asks for commits. Each task ends with verification and diff checks instead of a commit command.

## Reference Files

- Spec: `docs/superpowers/specs/2026-06-17-factory-list-design.md`
- Core source to modify: `Sources/FactoryKit/FactoryKit/Containers.swift`
- Core source to modify: `Sources/FactoryKit/FactoryKit/Injections.swift`
- Core source to create: `Sources/FactoryKit/FactoryKit/FactoryLists.swift`
- Tests to create: `Tests/FactoryTests/XCTests/FactoryListTests.swift`
- DocC to create: `Sources/FactoryKit/FactoryKit.docc/Advanced/Lists.md`
- DocC index to modify: `Sources/FactoryKit/FactoryKit.docc/FactoryKit.md`

## File Structure

- `Sources/FactoryKit/FactoryKit/FactoryLists.swift`
  - Defines `FactoryList<T>`, `FactoryListItem<T>`, and `FactoryListSnapshot<T>`.
  - Defines internal list entry and item key types.
  - Extends `ManagedContainer` with `list(key:scope:)`.

- `Sources/FactoryKit/FactoryKit/Containers.swift`
  - Adds manager-owned list registry storage.
  - Extends `reset`, `push`, and `pop` to include list registrations.

- `Sources/FactoryKit/FactoryKit/Injections.swift`
  - Adds `@LazyInjected(\.list)` support for `FactoryList<T>` so the design's consumption example compiles.
  - Uses a small resolver abstraction inside `LazyInjected` so list reset can call `FactoryList.reset`.

- `Tests/FactoryTests/XCTests/FactoryListTests.swift`
  - Contains isolated list-only services and containers.
  - Verifies empty lists, order, duplicate behavior, snapshot behavior, scope behavior, reset/push/pop, lazy injection, and concurrent append/resolve.

- `Sources/FactoryKit/FactoryKit.docc/Advanced/Lists.md`
  - Documents service-list use cases and API rules.

- `Sources/FactoryKit/FactoryKit.docc/FactoryKit.md`
  - Adds the new article to Advanced Topics.

## Task 1: Add Failing API Shape Tests

**Files:**
- Create: `Tests/FactoryTests/XCTests/FactoryListTests.swift`

- [ ] **Step 1: Create the test file with compile-failing API tests**

Add this file:

```swift
import XCTest
@testable import FactoryKit

private protocol ListObserver: AnyObject {
    var id: UUID { get }
    var name: String { get }
    func handle() -> String
}

private final class TestObserver: ListObserver {
    let id = UUID()
    let name: String

    init(_ name: String) {
        self.name = name
    }

    func handle() -> String {
        name
    }
}

private final class AlternateObserver: ListObserver {
    let id = UUID()
    let name: String

    init(_ name: String) {
        self.name = name
    }

    func handle() -> String {
        "alternate-\(name)"
    }
}

private final class FactoryListTestContainer: SharedContainer {
    @TaskLocal static var shared = FactoryListTestContainer()

    let manager = ContainerManager()

    var observers: FactoryList<ListObserver> {
        list(scope: .shared)
    }

    var firstObserver: Factory<ListObserver> {
        self { TestObserver("first") }
    }

    var secondObserver: Factory<ListObserver> {
        self { TestObserver("second") }
    }

    var cachedObserver: Factory<ListObserver> {
        self { TestObserver("cached") }.cached
    }
}

final class FactoryListTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FactoryListTestContainer.shared.reset()
    }

    func testEmptyListResolvesToEmptySnapshot() {
        let snapshot = FactoryListTestContainer.shared.observers()

        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.count, 0)
    }

    func testKeyPathItemsResolveInRegistrationOrder() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)

        let snapshot = FactoryListTestContainer.shared.observers()

        XCTAssertEqual(snapshot.map { $0.handle() }, ["first", "second"])
    }
}
```

- [ ] **Step 2: Run the new focused test and confirm it fails to compile**

Run:

```bash
swift test --filter FactoryListTests
```

Expected result:

```text
error: cannot find type 'FactoryList' in scope
```

or an equivalent compile error for missing `FactoryList`, `FactoryListSnapshot`, or `list(scope:)`.

## Task 2: Add Core List Types and Empty/KeyPath Resolution

**Files:**
- Create: `Sources/FactoryKit/FactoryKit/FactoryLists.swift`
- Modify: `Sources/FactoryKit/FactoryKit/Containers.swift`
- Test: `Tests/FactoryTests/XCTests/FactoryListTests.swift`

- [ ] **Step 1: Add manager storage for list registrations**

In `Sources/FactoryKit/FactoryKit/Containers.swift`, inside `ContainerManager`, add list state next to `options` and `cache`:

```swift
    internal typealias FactoryListOptionsMap = [FactoryKey:FactoryListOptions]
    internal var lists: FactoryListOptionsMap = .init(minimumCapacity: 32)
```

Change the stack declaration from:

```swift
    internal var stack: [(FactoryOptionsMap, Scope.Cache.CacheMap, InternalState)] = []
```

to:

```swift
    internal var stack: [(FactoryOptionsMap, Scope.Cache.CacheMap, InternalState, FactoryListOptionsMap)] = []
```

Update `.all` reset:

```swift
            case .all:
                self.options.removeAll(keepingCapacity: true)
                self.lists.removeAll(keepingCapacity: true)
                self.cache.reset()
                self.state = .init()
```

Update `.registration` reset:

```swift
            case .registration:
                for (key, option) in self.options {
                    var mutable = option
                    mutable.registration = nil
                    self.options[key] = mutable
                }
                self.lists.removeAll(keepingCapacity: true)
                self.state.autoRegistrationCheckNeeded = true
```

Update `push()`:

```swift
    public func push() {
        lock.withLock {
            stack.append((options, cache.clone().cache, state, lists))
        }
    }
```

Update `pop()`:

```swift
    public func pop() {
        lock.withLock {
            if let values = stack.popLast() {
                options = values.0
                cache.assign(map: values.1)
                state = values.2
                lists = values.3
            }
        }
    }
```

After `FactoryOptions`, add:

```swift
internal struct FactoryListOptions {
    var keys: Set<FactoryListItemKey> = []
    var items: [AnyFactoryListEntry] = []
}
```

- [ ] **Step 2: Add `FactoryLists.swift` with minimal key-path support**

Create `Sources/FactoryKit/FactoryKit/FactoryLists.swift`:

```swift
//
// FactoryLists.swift
//
// GitHub Repo and Documentation: https://github.com/hmlongco/Factory
//
// Copyright © 2022-2025 Michael Long. All rights reserved.
//

import Foundation

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
        let manager = container.manager
        manager.lock.lock()
        container.unsafeCheckAutoRegistration()
        let entries = manager.lists[key]?.items.compactMap { $0 as? TypedFactoryListEntry<T> } ?? []
        manager.lock.unlock()
        return FactoryListSnapshot(entries: entries)
    }

    @discardableResult
    public func append<C: SharedContainer>(_ keyPath: KeyPath<C, Factory<T>>) -> Self {
        let target = (container as? C) ?? C.shared
        let factory = target[keyPath: keyPath]
        let itemKey = FactoryListItemKey.factory(container: C.self, key: factory.registration.key)
        let entry = TypedFactoryListEntry<T>(key: itemKey) {
            target[keyPath: keyPath].resolve()
        }
        append(entry)
        return self
    }

    @discardableResult
    public func reset(_ options: FactoryResetOptions = .all) -> Self {
        guard options == .all || options == .registration else {
            return self
        }
        container.manager.lock.withLock {
            container.manager.lists.removeValue(forKey: key)
        }
        return self
    }

    internal func append(_ entry: TypedFactoryListEntry<T>, configure: () -> Void = {}) {
        let manager = container.manager
        manager.lock.withLock {
            container.unsafeCheckAutoRegistration()
            var options = manager.lists[key] ?? FactoryListOptions()
            guard options.keys.insert(entry.key).inserted else {
                #if DEBUG
                manager.logger("FACTORY: Duplicate FactoryList item ignored for \(entry.key.description)")
                #endif
                return
            }
            configure()
            options.items.append(entry)
            manager.lists[key] = options
        }
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

internal protocol AnyFactoryListEntry {
    var key: FactoryListItemKey { get }
}

internal struct TypedFactoryListEntry<T>: AnyFactoryListEntry {
    let key: FactoryListItemKey
    let resolve: () -> T
}

internal enum FactoryListItemKey: Hashable, CustomStringConvertible {
    case factory(container: ObjectIdentifier, key: FactoryKey)
    case inline(key: FactoryKey)

    static func factory<C>(container: C.Type, key: FactoryKey) -> Self {
        .factory(container: ObjectIdentifier(container), key: key)
    }

    var description: String {
        switch self {
        case .factory(_, let key):
            return "factory:\(key.key)"
        case .inline(let key):
            return "inline:\(key.key)"
        }
    }
}
```

- [ ] **Step 3: Run the focused tests**

Run:

```bash
swift test --filter FactoryListTests
```

Expected result:

```text
Test Suite 'FactoryListTests' passed
```

If Swift emits a concurrency warning about `FactoryListSnapshot` sendability, do not silence it with `@unchecked Sendable` unless a concrete test or compiler error requires it.

## Task 3: Add Inline Items and Scope Semantics

**Files:**
- Modify: `Sources/FactoryKit/FactoryKit/FactoryLists.swift`
- Modify: `Tests/FactoryTests/XCTests/FactoryListTests.swift`

- [ ] **Step 1: Add failing tests for inline scope behavior**

Append these tests inside `FactoryListTests`:

```swift
    func testInlineItemUsesListDefaultScope() {
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "inline") {
                TestObserver("inline")
            }
        )

        let snapshot = FactoryListTestContainer.shared.observers()
        let first = snapshot[snapshot.startIndex]
        let second = snapshot[snapshot.startIndex]

        XCTAssertTrue(first === second)
        XCTAssertEqual(first.handle(), "inline")
    }

    func testInlineItemScopeOverridesListDefaultScope() {
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "inline-unique") {
                TestObserver("inline-unique")
            }
            .unique
        )

        let snapshot = FactoryListTestContainer.shared.observers()
        let first = snapshot[snapshot.startIndex]
        let second = snapshot[snapshot.startIndex]

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.handle(), "inline-unique")
        XCTAssertEqual(second.handle(), "inline-unique")
    }

    func testKeyPathItemKeepsOwnFactoryScope() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.cachedObserver)

        let snapshot = FactoryListTestContainer.shared.observers()
        let firstA = snapshot[snapshot.startIndex]
        let firstB = snapshot[snapshot.startIndex]
        let cachedA = snapshot[snapshot.index(after: snapshot.startIndex)]
        let cachedB = snapshot[snapshot.index(after: snapshot.startIndex)]

        XCTAssertFalse(firstA === firstB)
        XCTAssertTrue(cachedA === cachedB)
    }
```

- [ ] **Step 2: Run the scope tests and confirm missing `FactoryListItem`**

Run:

```bash
swift test --filter FactoryListTests/testInlineItemUsesListDefaultScope
```

Expected result:

```text
error: cannot find 'FactoryListItem' in scope
```

- [ ] **Step 3: Implement `FactoryListItem<T>` and inline append**

In `FactoryLists.swift`, after `FactoryList`, add:

```swift
public nonisolated struct FactoryListItem<T> {
    internal let key: FactoryKey
    internal let factory: VoidFactoryType<T>
    internal var scope: Scope?

    public init(key: StaticString, _ factory: @escaping VoidFactoryType<T>) {
        self.key = FactoryKey(type: T.self, key: key)
        self.factory = factory
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
```

Inside `FactoryList<T>`, add this public append overload:

```swift
    @discardableResult
    public func append(_ item: FactoryListItem<T>) -> Self {
        let itemKey = FactoryListItemKey.inline(key: item.key)
        let registration = FactoryRegistration<Void,T>(key: item.key.key, container: container) {
            item.factory()
        }
        let entry = TypedFactoryListEntry<T>(key: itemKey) {
            registration.resolve(with: ())
        }
        append(entry) {
            if let scope = item.scope ?? defaultScope {
                registration.register(scope: scope)
            }
        }
        return self
    }
```

- [ ] **Step 4: Run the scope tests**

Run:

```bash
swift test --filter FactoryListTests/testInlineItemUsesListDefaultScope
swift test --filter FactoryListTests/testInlineItemScopeOverridesListDefaultScope
swift test --filter FactoryListTests/testKeyPathItemKeepsOwnFactoryScope
```

Expected result for each command:

```text
Test Suite 'FactoryListTests' passed
```

If `FactoryRegistration` does not allow `item.key.key` access because of access level, keep `FactoryListItem` in `FactoryLists.swift`; `FactoryKey.key` is internal and accessible inside the module.

## Task 4: Add Duplicate-Key and Snapshot Semantics

**Files:**
- Modify: `Tests/FactoryTests/XCTests/FactoryListTests.swift`
- Modify: `Sources/FactoryKit/FactoryKit/FactoryLists.swift`

- [ ] **Step 1: Add duplicate-key and snapshot tests**

Append these tests inside `FactoryListTests`:

```swift
    func testDuplicateKeyPathItemIsSkipped() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)

        let snapshot = FactoryListTestContainer.shared.observers()

        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.map { $0.handle() }, ["first", "second"])
    }

    func testDuplicateInlineItemKeyIsSkippedWithoutReplacing() {
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "same-inline") {
                TestObserver("original")
            }
        )
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "same-inline") {
                AlternateObserver("replacement")
            }
        )

        let snapshot = FactoryListTestContainer.shared.observers()

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[snapshot.startIndex].handle(), "original")
    }

    func testSnapshotDoesNotSeeLaterAppends() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        let oldSnapshot = FactoryListTestContainer.shared.observers()

        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)
        let newSnapshot = FactoryListTestContainer.shared.observers()

        XCTAssertEqual(oldSnapshot.map { $0.handle() }, ["first"])
        XCTAssertEqual(newSnapshot.map { $0.handle() }, ["first", "second"])
    }
```

- [ ] **Step 2: Run the duplicate and snapshot tests**

Run:

```bash
swift test --filter FactoryListTests/testDuplicateKeyPathItemIsSkipped
swift test --filter FactoryListTests/testDuplicateInlineItemKeyIsSkippedWithoutReplacing
swift test --filter FactoryListTests/testSnapshotDoesNotSeeLaterAppends
```

Expected result:

```text
Test Suite 'FactoryListTests' passed
```

- [ ] **Step 3: Fix any duplicate-key failure in `FactoryList.append(_:)`**

If duplicate-key tests fail, ensure `FactoryList.append(_ entry:)` mutates list state only after this guard:

```swift
            guard options.keys.insert(entry.key).inserted else {
                #if DEBUG
                manager.logger("FACTORY: Duplicate FactoryList item ignored for \(entry.key.description)")
                #endif
                return
            }
```

- [ ] **Step 4: Re-run the full FactoryList test file**

Run:

```bash
swift test --filter FactoryListTests
```

Expected result:

```text
Test Suite 'FactoryListTests' passed
```

## Task 5: Add Reset, Push, Pop, and Lazy Injection Tests

**Files:**
- Modify: `Tests/FactoryTests/XCTests/FactoryListTests.swift`
- Modify: `Sources/FactoryKit/FactoryKit/Injections.swift`
- Modify: `Sources/FactoryKit/FactoryKit/FactoryLists.swift`

- [ ] **Step 1: Add reset and push/pop tests**

Append these tests inside `FactoryListTests`:

```swift
    func testResetRegistrationClearsListItems() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)

        FactoryListTestContainer.shared.reset(options: .registration)

        XCTAssertTrue(FactoryListTestContainer.shared.observers().isEmpty)
    }

    func testResetAllClearsListItems() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)

        FactoryListTestContainer.shared.reset(options: .all)

        XCTAssertTrue(FactoryListTestContainer.shared.observers().isEmpty)
    }

    func testResetScopeKeepsListItems() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)

        FactoryListTestContainer.shared.reset(options: .scope)

        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first"])
    }

    func testFactoryListResetClearsOnlyThatList() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)

        FactoryListTestContainer.shared.observers.reset()

        XCTAssertTrue(FactoryListTestContainer.shared.observers().isEmpty)
    }

    func testPushPopRestoresListRegistrations() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        FactoryListTestContainer.shared.manager.push()
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)

        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first", "second"])

        FactoryListTestContainer.shared.manager.pop()

        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first"])
    }
```

- [ ] **Step 2: Add lazy injection test**

Add this helper type above `FactoryListTests`:

```swift
private final class FactoryListConsumer {
    @LazyInjected(\FactoryListTestContainer.observers) var observers: FactoryListSnapshot<ListObserver>

    func names() -> [String] {
        observers.map { $0.handle() }
    }
}
```

Append this test inside `FactoryListTests`:

```swift
    func testLazyInjectedFactoryListResolvesSnapshot() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)

        let consumer = FactoryListConsumer()

        XCTAssertEqual(consumer.names(), ["first"])

        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)

        XCTAssertEqual(consumer.names(), ["first"])
        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first", "second"])
    }
```

- [ ] **Step 3: Run lazy injection test and confirm initializer is missing**

Run:

```bash
swift test --filter FactoryListTests/testLazyInjectedFactoryListResolvesSnapshot
```

Expected result:

```text
error: cannot convert value of type 'KeyPath<FactoryListTestContainer, FactoryList<ListObserver>>' to expected argument type 'KeyPath<FactoryListTestContainer, Factory<FactoryListSnapshot<ListObserver>>>'
```

or an equivalent error showing `LazyInjected` does not yet accept `FactoryList`.

- [ ] **Step 4: Refactor `LazyInjected` to use a resolver abstraction**

In `Sources/FactoryKit/FactoryKit/Injections.swift`, replace the stored thunk in `LazyInjected<T>`:

```swift
    private var thunk: () -> Factory<T>
```

with:

```swift
    private struct Source {
        let resolve: () -> T
        let reset: (FactoryResetOptions) -> Void
        let factory: () -> Factory<T>
    }

    private var source: Source
```

Change the existing Factory initializers to:

```swift
    public init(_ keyPath: KeyPath<Container, Factory<T>>) {
        self.source = Source(
            resolve: { Container.shared[keyPath: keyPath].resolve() },
            reset: { Container.shared[keyPath: keyPath].reset($0) },
            factory: { Container.shared[keyPath: keyPath] }
        )
        self.storage = Storage()
    }

    public init<C:SharedContainer>(_ keyPath: KeyPath<C, Factory<T>>) {
        self.source = Source(
            resolve: { C.shared[keyPath: keyPath].resolve() },
            reset: { C.shared[keyPath: keyPath].reset($0) },
            factory: { C.shared[keyPath: keyPath] }
        )
        self.storage = Storage()
    }
```

Add the FactoryList initializer:

```swift
    public init<C: SharedContainer, Element>(_ keyPath: KeyPath<C, FactoryList<Element>>) where T == FactoryListSnapshot<Element> {
        self.source = Source(
            resolve: { C.shared[keyPath: keyPath].resolve() },
            reset: { C.shared[keyPath: keyPath].reset($0) },
            factory: { C.shared[keyPath: keyPath].snapshotFactory }
        )
        self.storage = Storage()
    }
```

Update `wrappedValue` getter:

```swift
                    storage.dependency = source.resolve()
```

Update `factory`:

```swift
        source.factory()
```

Update `resolve(reset:)`:

```swift
            source.reset(options)
            storage.dependency = source.resolve()
            storage.initialized = true
```

- [ ] **Step 5: Run reset, push/pop, and lazy injection tests**

Run:

```bash
swift test --filter FactoryListTests/testResetRegistrationClearsListItems
swift test --filter FactoryListTests/testResetAllClearsListItems
swift test --filter FactoryListTests/testResetScopeKeepsListItems
swift test --filter FactoryListTests/testFactoryListResetClearsOnlyThatList
swift test --filter FactoryListTests/testPushPopRestoresListRegistrations
swift test --filter FactoryListTests/testLazyInjectedFactoryListResolvesSnapshot
```

Expected result:

```text
Test Suite 'FactoryListTests' passed
```

## Task 6: Add Concurrency Coverage

**Files:**
- Modify: `Tests/FactoryTests/XCTests/FactoryListTests.swift`

- [ ] **Step 1: Add concurrent append and resolve test**

Append this test inside `FactoryListTests`:

```swift
    func testConcurrentAppendAndResolveDoesNotDuplicateSameKey() {
        let queue = DispatchQueue(label: "factory-list-test", attributes: .concurrent)
        let group = DispatchGroup()

        for _ in 0..<200 {
            group.enter()
            queue.async {
                FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
                group.leave()
            }

            group.enter()
            queue.async {
                _ = FactoryListTestContainer.shared.observers().map { $0.handle() }
                group.leave()
            }
        }

        let completed = group.wait(timeout: .now() + 10)

        XCTAssertEqual(completed, .success)
        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first"])
    }
```

- [ ] **Step 2: Run concurrency test**

Run:

```bash
swift test --filter FactoryListTests/testConcurrentAppendAndResolveDoesNotDuplicateSameKey
```

Expected result:

```text
Test Suite 'FactoryListTests' passed
```

- [ ] **Step 3: Run the full FactoryList test suite**

Run:

```bash
swift test --filter FactoryListTests
```

Expected result:

```text
Test Suite 'FactoryListTests' passed
```

## Task 7: Add DocC Documentation

**Files:**
- Create: `Sources/FactoryKit/FactoryKit.docc/Advanced/Lists.md`
- Modify: `Sources/FactoryKit/FactoryKit.docc/FactoryKit.md`

- [ ] **Step 1: Create the Lists article**

Create `Sources/FactoryKit/FactoryKit.docc/Advanced/Lists.md`:

````markdown
# Service Lists

Register multiple services for one protocol and resolve them as an ordered collection.

## Overview

Most Factory registrations produce one dependency. Some systems need a set of dependencies that all conform to the same protocol, such as observers, plugins, handlers, or feature contributors.

`FactoryList` supports that pattern without automatic scanning or runtime discovery. Modules explicitly append their factories to a list, usually from `AutoRegistering`, and consumers resolve a snapshot of the registered items.

## Defining a List

Define a list on a container with `list(scope:)`.

```swift
protocol ObserverService: AnyObject {
    func handle()
}

extension Container {
    var observers: FactoryList<any ObserverService> {
        list(scope: .shared)
    }
}
```

The list's scope is only the default scope for inline items. It does not change the scope of factories appended by key path.

## Registering Factory Items

A module can contribute an existing factory.

```swift
extension Container {
    var analyticsObserver: Factory<any ObserverService> {
        self { AnalyticsObserver() }.cached
    }

    func registerAnalyticsObserver() {
        observers.append(\.analyticsObserver)
    }
}
```

The contributed item follows `analyticsObserver`'s own scope. If that factory is `.cached`, repeated list access reuses the cached instance. If it is unique, each access creates a new instance.

## Registering Inline Items

You can also append an inline item.

```swift
extension Container {
    func registerInlineObserver() {
        observers.append(
            FactoryListItem(key: "inline-observer") {
                InlineObserver()
            }
            .shared
        )
    }
}
```

If the inline item does not set a scope, it uses the list's default scope. If neither the item nor the list defines a scope, the item behaves as unique.

## Wiring Lists

FactoryList does not scan modules automatically. Call contribution functions from your app or aggregation module.

```swift
extension Container: @retroactive AutoRegistering {
    func autoRegister() {
        registerAnalyticsObserver()
        registerInlineObserver()
    }
}
```

Repeated registration is safe. If the same item key is appended more than once, the first registration wins and later duplicates are ignored.

## Resolving a Snapshot

Resolving a list returns a snapshot.

```swift
let snapshot = Container.shared.observers()

for observer in snapshot {
    observer.handle()
}
```

`FactoryListSnapshot` conforms to `RandomAccessCollection`, so collection APIs such as `map`, `filter`, and subscript access are available.

```swift
let first = snapshot[snapshot.startIndex]
let names = snapshot.map { String(describing: type(of: $0)) }
```

Accessing an element resolves that item. The snapshot does not store an already materialized array of service instances.

## Snapshot Semantics

A snapshot contains the items that were registered when the list was resolved.

```swift
let firstSnapshot = Container.shared.observers()
Container.shared.observers.append(\.anotherObserver)
let secondSnapshot = Container.shared.observers()
```

`firstSnapshot` does not see `anotherObserver`. `secondSnapshot` does.

## Lazy Injection

Lists can be resolved lazily.

```swift
final class ObserverCenter {
    @LazyInjected(\.observers) private var observers

    func emit() {
        for observer in observers {
            observer.handle()
        }
    }
}
```

The lazy wrapper stores one snapshot. Later appends do not change that already injected snapshot.

## Reset Behavior

List registrations are registration state.

```swift
Container.shared.reset(options: .registration)
Container.shared.reset(options: .all)
```

Both calls clear list registrations. Scope reset keeps list registrations.

```swift
Container.shared.reset(options: .scope)
```

Use `FactoryList.reset()` to clear one list.

```swift
Container.shared.observers.reset()
```
````

- [ ] **Step 2: Link the article from the FactoryKit landing page**

Open `Sources/FactoryKit/FactoryKit.docc/FactoryKit.md` and add `Lists` to the existing Advanced Topics list. If the file uses a topic list, add this line next to `Modules`, `Optionals`, `Tags`, or similar advanced articles:

```markdown
- <doc:Lists>
```

- [ ] **Step 3: Run a documentation-oriented smoke check**

Run:

```bash
swift package generate-documentation --target FactoryKit
```

Expected result:

```text
Build complete!
```

If the command fails because the `swift-docc-plugin` dependency cannot be downloaded due restricted network access, record that as an environment failure and still run the source tests in Task 8.

## Task 8: Full Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Re-read changed source files**

Run:

```bash
sed -n '1,260p' Sources/FactoryKit/FactoryKit/FactoryLists.swift
sed -n '300,430p' Sources/FactoryKit/FactoryKit/Containers.swift
sed -n '90,190p' Sources/FactoryKit/FactoryKit/Injections.swift
sed -n '1,360p' Tests/FactoryTests/XCTests/FactoryListTests.swift
```

Expected result:

```text
The output matches the planned FactoryList API, manager state changes, LazyInjected overload, and tests.
```

- [ ] **Step 2: Run FactoryList tests**

Run:

```bash
swift test --filter FactoryListTests
```

Expected result:

```text
Test Suite 'FactoryListTests' passed
```

- [ ] **Step 3: Run the full Swift test suite**

Run:

```bash
swift test
```

Expected result:

```text
Test Suite 'All tests' passed
```

The exact final test-suite name can differ by SwiftPM version. Treat a zero exit code as pass.

- [ ] **Step 4: Check formatting and whitespace**

Run:

```bash
git diff --check
```

Expected result:

```text
No output.
```

- [ ] **Step 5: Inspect final diff scope**

Run:

```bash
git status --short
git diff --stat
```

Expected result:

```text
Only FactoryList source, tests, DocC article, DocC index, and the local planning/spec docs are changed.
```

Do not commit unless the user explicitly asks for a commit.
