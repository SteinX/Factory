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

    var unscopedObservers: FactoryList<ListObserver> {
        list()
    }

    var alternateObservers: FactoryList<ListObserver> {
        list(scope: .cached)
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

    var inlineObserver: Factory<ListObserver> {
        self(key: "inline") { TestObserver("factory-inline") }.cached
    }
}

private final class InstanceOnlyFactoryListContainer: ManagedContainer {
    let manager = ContainerManager()

    var observers: FactoryList<ListObserver> {
        list(scope: .shared)
    }

    var observer: Factory<ListObserver> {
        self { TestObserver("instance-only") }
    }
}

extension Container {
    fileprivate var defaultObservers: FactoryList<ListObserver> {
        list(scope: .shared)
    }

    fileprivate var defaultObserver: Factory<ListObserver> {
        self { TestObserver("default") }
    }
}

private final class FactoryListConsumer {
    @LazyInjected(\FactoryListTestContainer.observers) var observers: FactoryListSnapshot<ListObserver>

    func names() -> [String] {
        observers.map { $0.handle() }
    }
}

private final class DefaultFactoryListConsumer {
    @LazyInjected(\.defaultObservers) var observers: FactoryListSnapshot<ListObserver>

    func names() -> [String] {
        observers.map { $0.handle() }
    }
}

final class FactoryListTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Container.shared.reset()
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

    func testListScopeDoesNotCacheSnapshots() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        let firstSnapshot = FactoryListTestContainer.shared.observers.snapshotFactory()

        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)
        let secondSnapshot = FactoryListTestContainer.shared.observers.snapshotFactory()

        XCTAssertEqual(firstSnapshot.map { $0.handle() }, ["first"])
        XCTAssertEqual(secondSnapshot.map { $0.handle() }, ["first", "second"])
    }

    func testKeyPathItemUsesOwningContainerInstanceWhenTypesMatch() {
        let container = FactoryListTestContainer()
        container.firstObserver.register { TestObserver("instance") }
        FactoryListTestContainer.shared.firstObserver.register { TestObserver("shared") }

        container.observers.append(\FactoryListTestContainer.firstObserver)

        XCTAssertEqual(container.observers().map { $0.handle() }, ["instance"])
        XCTAssertTrue(FactoryListTestContainer.shared.observers().isEmpty)
    }

    func testManagedContainerKeyPathItemsResolveOnOwningInstance() {
        let container = InstanceOnlyFactoryListContainer()
        container.observer.register { TestObserver("registered-instance") }

        container.observers.append(\InstanceOnlyFactoryListContainer.observer)

        XCTAssertEqual(container.observers().map { $0.handle() }, ["registered-instance"])
    }

    func testKeyPathItemDoesNotRetainOwningContainerInstance() {
        weak var weakContainer: InstanceOnlyFactoryListContainer?

        do {
            let container = InstanceOnlyFactoryListContainer()
            weakContainer = container
            container.observers.append(\InstanceOnlyFactoryListContainer.observer)

            XCTAssertEqual(container.observers().map { $0.handle() }, ["instance-only"])
        }

        XCTAssertNil(weakContainer)
    }

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

    func testUnscopedInlineItemIgnoresManagerDefaultScope() {
        FactoryListTestContainer.shared.manager.defaultScope = .cached
        FactoryListTestContainer.shared.unscopedObservers.append(
            FactoryListItem(key: "unscoped-inline") {
                TestObserver("unscoped-inline")
            }
        )

        let snapshot = FactoryListTestContainer.shared.unscopedObservers()
        let first = snapshot[snapshot.startIndex]
        let second = snapshot[snapshot.startIndex]

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.handle(), "unscoped-inline")
        XCTAssertEqual(second.handle(), "unscoped-inline")
    }

    func testInlineItemDoesNotCollideWithSameKeyFactory() {
        FactoryListTestContainer.shared.inlineObserver.register {
            TestObserver("registered-factory")
        }
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "inline") {
                TestObserver("list-inline")
            }
            .cached
        )

        let inline = FactoryListTestContainer.shared.observers()[0]
        let factory = FactoryListTestContainer.shared.inlineObserver()

        XCTAssertEqual(inline.handle(), "list-inline")
        XCTAssertEqual(factory.handle(), "registered-factory")
        XCTAssertFalse(inline === factory)
    }

    func testSameInlineItemKeyIsIsolatedAcrossLists() {
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "same-inline") {
                TestObserver("primary-inline")
            }
            .cached
        )
        FactoryListTestContainer.shared.alternateObservers.append(
            FactoryListItem(key: "same-inline") {
                TestObserver("alternate-inline")
            }
            .cached
        )

        let primary = FactoryListTestContainer.shared.observers()[0]
        let alternate = FactoryListTestContainer.shared.alternateObservers()[0]

        XCTAssertEqual(primary.handle(), "primary-inline")
        XCTAssertEqual(alternate.handle(), "alternate-inline")
        XCTAssertFalse(primary === alternate)
    }

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

        let snapshot = FactoryListTestContainer.shared.observers()

        XCTAssertEqual(snapshot.map { $0.handle() }, ["first"])
    }

    func testFactoryListResetClearsOnlyThatList() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        FactoryListTestContainer.shared.alternateObservers.append(\FactoryListTestContainer.secondObserver)

        FactoryListTestContainer.shared.observers.reset(.registration)

        XCTAssertTrue(FactoryListTestContainer.shared.observers().isEmpty)
        XCTAssertEqual(FactoryListTestContainer.shared.alternateObservers().map { $0.handle() }, ["second"])
    }

    func testFactoryListResetAllClearsCachedInlineItemScope() {
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "reset-inline") {
                TestObserver("before-reset")
            }
            .cached
        )
        let before = FactoryListTestContainer.shared.observers()[0]

        FactoryListTestContainer.shared.observers.reset(.all)
        FactoryListTestContainer.shared.observers.append(
            FactoryListItem(key: "reset-inline") {
                TestObserver("after-reset")
            }
            .cached
        )
        let after = FactoryListTestContainer.shared.observers()[0]

        XCTAssertEqual(before.handle(), "before-reset")
        XCTAssertEqual(after.handle(), "after-reset")
        XCTAssertFalse(before === after)
    }

    func testPushPopRestoresListRegistrations() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        FactoryListTestContainer.shared.manager.push()
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)

        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first", "second"])

        FactoryListTestContainer.shared.manager.pop()

        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first"])
    }

    func testLazyInjectedFactoryListResolvesSnapshot() {
        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        let consumer = FactoryListConsumer()

        XCTAssertEqual(consumer.names(), ["first"])

        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)

        XCTAssertEqual(consumer.names(), ["first"])
        XCTAssertEqual(FactoryListTestContainer.shared.observers().map { $0.handle() }, ["first", "second"])
    }

    func testLazyInjectedFactoryListProjectedFactoryBacksResolution() {
        let consumer = FactoryListConsumer()
        _ = consumer.$observers.factory.cached

        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.firstObserver)
        consumer.$observers.resolve(reset: .none)

        XCTAssertEqual(consumer.names(), ["first"])

        FactoryListTestContainer.shared.observers.append(\FactoryListTestContainer.secondObserver)
        consumer.$observers.resolve(reset: .none)

        XCTAssertEqual(consumer.names(), ["first"])
        XCTAssertEqual(consumer.$observers.factory().map { $0.handle() }, ["first"])
    }

    func testLazyInjectedFactoryListSupportsDefaultContainerKeyPath() {
        Container.shared.defaultObservers.append(\.defaultObserver)

        let consumer = DefaultFactoryListConsumer()

        XCTAssertEqual(consumer.names(), ["default"])
    }

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
}
