//
//  FactoryDemoTesting.swift
//  FactoryDemoTests
//
//  Created by Michael Long on 7/9/26.
//

import Testing

@testable import FactoryDemo

@Suite(.aac)
struct FactoryDemoTestingAA {

    @Test func testMockRegister() {
        let precache = AAViewModel()
        #expect(precache.name == "DefaultService")
        AAContainer.shared.service {
            AAMockService()
        }
        let sut = AAViewModel()
        #expect(sut.name == "MockService")
    }

    @Test func testMockExplicitRegister() {
        let precache = AAViewModel()
        #expect(precache.name == "DefaultService")
        AAContainer.shared.service.register {
            AAMockService()
        }
        let sut = AAViewModel()
        #expect(sut.name == "MockService")
    }

    @Test func testMockOnDebug() {
        let precache = AAViewModel()
        #expect(precache.name == "DefaultService")
        AAContainer.shared.service.onDebug {
            AAMockService()
        }
        AAContainer.shared.service.reset(.scope)
        let sut = AAViewModel()
        #expect(sut.name == "MockService")
    }


    @Test func testMockOnTest() {
        let precache = AAViewModel()
        #expect(precache.name == "DefaultService")
        AAContainer.shared.service.onTest {
            AAMockService()
        }
        AAContainer.shared.service.reset(.scope)
        let sut = AAViewModel()
        #expect(sut.name == "MockService")
    }

}

/// Provides test trait for AAContainer
extension Trait where Self == ContainerTrait<AAContainer> {
    public static var aac: ContainerTrait<AAContainer> {
        .init(shared: AAContainer.$shared, container: .init())
    }
}
