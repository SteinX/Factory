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
    @State var viewModel = ContentViewModel()
    var body: some View {
        VStack {
            Text("Hello, \(viewModel.name)!")
            Button("Reload") {
                viewModel.reload()
            }
        }
        .padding()
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            viewModel.load()
        }
    }
}

#Preview {
    // Formal registration of dependent service
    let _ = Container.shared.myService.register { MockService("MockService 1") }
    ContentView()

    // Sugared registration
    Container.shared.myService { MockService("MockService 2") }
    ContentView()
}

@Observable
class ContentViewModel {
    @ObservationIgnored @Injected(\.myService) var myService
    private(set) var name: String = "Loading"
    func load() {
        name = myService.name
    }
    func reload() {
        name = "Service Reloaded"
    }
}

protocol MyProtocol {
    var name: String { get }
}

class MyService: MyProtocol {
    var name = "MyService"
}

class MockService: MyProtocol {
    var name: String
    init(_ name: String = "MockService") {
        self.name = name
    }
}

extension Container {
    @MainActor var myService: Factory<MyProtocol> {
        self { MyService() }
    }
}
