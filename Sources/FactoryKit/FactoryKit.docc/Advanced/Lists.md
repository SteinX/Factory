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

The list scope is only the default scope for inline items. It does not change the scope of factories appended by key path.

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

If the inline item does not set a scope, it uses the list default scope. If neither the item nor the list defines a scope, the item behaves as unique.

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
