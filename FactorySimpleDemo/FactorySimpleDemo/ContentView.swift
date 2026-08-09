import SwiftUI
import FactoryKit

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @Injected(\.myClass) var myClass
    var body: some View {
        Text("Hello, \(myClass.name)!")
            .padding()
    }
}

#Preview {
    // Formal registration
    let _ = Container.shared.myClass.register { MockClass("MockClass 1") }
    ContentView()

    // Sugared registration
    Container.shared.myClass { MockClass("MockClass 2") }
    ContentView()
}

protocol MyProtocol {
    var name: String { get }
}

class MyClass: MyProtocol {
    var name = "MyClass"
}

class MockClass: MyProtocol {
    let name: String
    init(_ name: String = "MockClass") {
        self.name = name
    }
}

extension Container {
    @MainActor var myClass: Factory<MyProtocol> {
        self { MyClass() }
    }
}
