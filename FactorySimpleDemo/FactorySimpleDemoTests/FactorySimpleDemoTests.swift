//
//  FactorySimpleDemoTests.swift
//  FactorySimpleDemoTests
//
//  Created by Michael Long on 7/9/26.
//

import Testing
import FactoryKit
import FactoryTesting

@testable import FactoryTestingTest

@MainActor
@Suite(.container)
struct FactoryTestingTestTests {

    @Test func example1() async throws {
        let a = Container.shared.myClass()
        #expect(a.name == "MyClass")
    }

    @Test func example2() async throws {
        Container.shared.myClass { MockClass() }
        let a = Container.shared.myClass()
        #expect(a.name == "MockClass")
    }

}
