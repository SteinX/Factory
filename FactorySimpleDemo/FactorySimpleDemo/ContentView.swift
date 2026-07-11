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
    Container.shared.myClass { MockClass() }
    ContentView()
}

protocol MyProtocol {
    var name: String { get }
}

class MyClass: MyProtocol {
    var name = "MyClass"
}

class MockClass: MyProtocol {
    var name = "MockClass"
}

extension Container {
    @MainActor var myClass: Factory<MyProtocol> {
        self { MyClass() }
    }
}
