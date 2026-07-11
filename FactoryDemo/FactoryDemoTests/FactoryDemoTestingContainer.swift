//
//  FactoryDemoTesting.swift
//  FactoryDemoTests
//
//  Created by Michael Long on 7/9/26.
//

import FactoryKit
import Testing

@testable import FactoryDemo

@MainActor
@Suite(.container)
struct FactoryDemoTestingContainer {

    @Test func testMockRegister() {
        let precache = Container.shared.myServiceType()
        #expect(precache.text() == "Mock Number 0!")
        Container.shared.myServiceType {
            MockService1()
        }
        let sut = Container.shared.myServiceType()
        #expect(sut.text() == "Mock World!")
    }

    @Test func testMockExplicitRegister() {
        let precache = Container.shared.myServiceType()
        #expect(precache.text() == "Mock Number 0!")
        Container.shared.myServiceType.register {
            MockService2()
        }
        let sut = Container.shared.myServiceType()
        #expect(sut.text() == "Mock Worlds!")
    }

    @Test func testMockOnDebug() {
        let precache = Container.shared.myServiceType()
        #expect(precache.text() == "Mock Number 0!")
        Container.shared.myServiceType.onDebug {
            MockService1()
        }
        let sut = Container.shared.myServiceType()
        #expect(sut.text() == "Mock World!")
    }


    @Test func testMockOnTest() {
        let precache = Container.shared.myServiceType()
        #expect(precache.text() == "Mock Number 0!")
        Container.shared.myServiceType.onTest {
            MockService2()
        }
        let sut = Container.shared.myServiceType()
        #expect(sut.text() == "Mock Worlds!")
    }

}
