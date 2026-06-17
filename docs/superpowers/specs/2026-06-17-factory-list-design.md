# FactoryList Design

## Background

Factory already handles single dependency registrations well. A module exposes a `Factory<T>` on a container, and consumers resolve that dependency through `Container.shared`, a passed container, or a property wrapper.

The missing case is a service collection. Multiple implementation modules may want to contribute observers, plugins, handlers, or other protocol-typed services into one ordered list. Without library support, the app has to manually resolve the center and call `addObserver` repeatedly during startup.

This design adds `FactoryList<T>` so modules can register ordered service contributions through Factory, while each contributed item keeps its own Factory lifecycle.

## Goals

- Support an ordered collection of service factories for a shared protocol type.
- Keep contribution registration explicit through `AutoRegistering` or an app-level aggregation module.
- Let consumers resolve a snapshot that behaves like a `RandomAccessCollection`.
- Resolve collection elements lazily when they are accessed.
- Preserve each item factory's own scope and lifecycle.
- Make duplicate registration safe by ignoring later contributions with the same key.
- Reuse container isolation, reset, push/pop, and locking behavior where possible.

## Non-Goals

- No automatic module scanning, link-time registration, macros, or code generation in the first version.
- No public `remove(key:)` or `replace(key:)` API in the first version.
- No caching of resolved service instances by `FactoryListSnapshot`.
- No promise/fatal-error behavior for empty lists. Empty lists are valid.

## Chosen Approach

Use `FactoryList<T>` backed by `ContainerManager` state.

`FactoryList<T>` is a lightweight transient value, like `Factory<T>`. It binds a `ManagedContainer`, a list key, and an optional default item scope. It does not own service instances or durable registration state.

Durable list registrations live in the owning container's `ContainerManager`. This matches the existing Factory model:

- the container owns registrations and scope caches;
- `Container.shared` task-local isolation works naturally;
- Swift Testing's `.container` trait gets isolated list registrations;
- `push`, `pop`, and `reset` can include list state.

Resolving a list returns `FactoryListSnapshot<T>`. The snapshot is immutable and contains the item registrations visible at resolve time.

## Public API Shape

Container helper:

```swift
extension ManagedContainer {
    public func list<T>(
        key: StaticString = #function,
        scope: Scope? = nil
    ) -> FactoryList<T>
}
```

List definition:

```swift
extension Container {
    var observerList: FactoryList<any IObserverService> {
        list(scope: .shared)
    }
}
```

Register a key-path item:

```swift
observerList.append(\.obsService)
observerList.append(\CustomContainer.obsService)
```

Register an inline item:

```swift
observerList.append(
    FactoryListItem(key: "inline") {
        InlineObserver()
    }
    .cached
)
```

Consume a list:

```swift
let observers = Container.shared.observerList()

for observer in observers {
    observer.handle()
}

let first = observers[observers.startIndex]
```

Property-wrapper consumption:

```swift
final class ObsCenterImpl {
    @LazyInjected(\.observerList) private var observers

    func emit() {
        for observer in observers {
            observer.handle()
        }
    }
}
```

`FactoryList<T>` itself is not a collection. It is the registration and resolution entry point. `FactoryListSnapshot<T>` is the collection.

## Core Types

### FactoryList<T>

Responsibilities:

- bind a list key to a `ManagedContainer`;
- append key-path and inline items;
- resolve the current item registry into a `FactoryListSnapshot<T>`;
- expose `callAsFunction()` and `resolve()` like `Factory<T>`.

`FactoryList<T>` should remain a cheap transient value. Users should define it as a computed container property, not as stored state.

### FactoryListItem<T>

Responsibilities:

- identify one contribution by a stable key;
- hold a resolver that can produce `T`;
- optionally hold a scope for inline items.

There are two item sources:

- key-path items, such as `append(\.obsService)`;
- inline items, such as `FactoryListItem(key: "inline") { InlineObserver() }`.

For key-path items, the target `Factory<T>` controls scope. The list's default scope must not change that factory.

For inline items, the item's own scope wins. If it has no scope, the list's default scope is used. If neither has a scope, access behaves like `.unique`.

### FactoryListSnapshot<T>

Responsibilities:

- store an immutable ordered array of item registrations;
- conform to `RandomAccessCollection`;
- resolve item values on element access.

The snapshot does not cache resolved services. Repeated access to the same index calls that item resolver again. Reuse depends on the item factory's own scope.

## Registration Flow

1. The app or aggregation module calls contribution functions from `Container.autoRegister()`.
2. A contribution function calls `observerList.append(...)`.
3. `append` checks container auto-registration state through the existing container path.
4. `append` locks the `ContainerManager`.
5. `append` checks whether the item key already exists for this list.
6. If the key is new, the item is appended.
7. If the key already exists, the new item is ignored and the original position and resolver remain unchanged.

Duplicate keys are first registration wins. This makes repeated startup registration safe and avoids duplicate observers.

## Resolve Flow

1. A consumer resolves `Container.shared.observerList()` or injects `@LazyInjected(\.observerList)`.
2. `FactoryList` locks the `ContainerManager`.
3. It copies the current item array for the list key.
4. It releases the lock and returns `FactoryListSnapshot<T>`.
5. Iterating or indexing the snapshot resolves each item independently.

The snapshot is fixed at resolve time. Later `append` calls are visible only to later snapshots.

## Scope Semantics

The list-level `scope` is only the default scope for inline items.

Key-path item:

```swift
observerList.append(\.obsService)
```

The lifecycle follows `obsService` exactly.

Inline item:

```swift
observerList.append(FactoryListItem(key: "inline") { InlineObserver() })
```

If the item has no explicit scope, it uses the list default scope.

Inline item with explicit scope:

```swift
observerList.append(
    FactoryListItem(key: "inline") { InlineObserver() }
        .cached
)
```

The item scope overrides the list default scope.

`FactoryListSnapshot` does not add another caching layer.

## Thread Safety

Use `ContainerManager.lock` for list registry mutation and snapshot creation.

- `append` runs under the manager lock.
- `resolve` copies the item array under the manager lock.
- Snapshot iteration does not hold the list registry lock.
- Concurrent appends do not mutate existing snapshots.
- Concurrent append and resolve should not crash or corrupt list order.

The implementation should avoid holding the list registry lock while resolving item values.

## Reset, Push, and Pop

List registrations are registration state.

- `manager.reset(.all)` clears list registrations.
- `manager.reset(.registration)` clears list registrations.
- `manager.reset(.scope)` does not clear list registrations.
- `manager.push()` saves list registrations.
- `manager.pop()` restores list registrations.

Provide `FactoryList.reset()` for a single list. Its first-version behavior is:

- `.all` and `.registration` clear that list's registered items;
- `.scope` is a no-op for the list registry;
- `.none` is a no-op.

Element factory scope caches are still managed by their owning factories and scopes.

## Error Handling and Debugging

- Resolving an empty list returns an empty snapshot.
- Duplicate item keys are ignored.
- DEBUG builds may log duplicate-key skips through `ContainerManager.logger`.
- Duplicate keys should not `fatalError`, throw, or replace existing items.
- Docs must state that `snapshot[index]` can create or resolve a service.

## Documentation Plan

Add a DocC article at `Sources/FactoryKit/FactoryKit.docc/Advanced/Lists.md`.

The article should explain:

- the cross-module service-list use case;
- explicit registration through `AutoRegistering`;
- key-path item registration;
- inline item registration;
- snapshot behavior;
- `RandomAccessCollection` support;
- scope rules;
- duplicate-key behavior;
- reset behavior.

The article should also warn that collection access resolves services and is not equivalent to reading from an already materialized `[T]`.

## Test Plan

Add `FactoryListTests` covering:

- resolving an empty list returns an empty snapshot;
- key-path items are iterated in registration order;
- `.unique` item factories create a new value on repeated access;
- `.cached` item factories reuse values on repeated access;
- `.shared` item factories weakly reuse values only while retained elsewhere;
- inline items use the list default scope when no item scope is provided;
- inline item scope overrides the list default scope;
- duplicate keys are skipped and do not alter order or implementation;
- an old snapshot does not see items appended after it was resolved;
- a new snapshot sees later appended items;
- `manager.reset(.registration)` clears list registrations;
- `manager.reset(.all)` clears list registrations;
- `manager.reset(.scope)` keeps list registrations;
- `push` and `pop` restore list registrations;
- concurrent append and resolve does not crash or duplicate same-key items.

## Implementation Notes

The implementation should keep changes narrow:

- add list-specific storage to `ContainerManager.InternalState` or adjacent manager-owned state;
- add a list key type parallel to `FactoryKey` if needed;
- add `FactoryList` and `FactoryListItem` in a new source file unless nearby existing files provide a clearer fit;
- extend `ManagedContainer` with `list(key:scope:)`;
- add tests before broad documentation generation.

Do not add automatic discovery, macros, runtime scanning, public removal, or replacement in the first version.
