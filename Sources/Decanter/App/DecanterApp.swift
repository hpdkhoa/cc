import SwiftUI
import DecanterCore

@main
struct DecanterApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Decanter") {
            ContentView()
                .environment(state)
                .task { await state.bootstrap() }
        }
        .defaultSize(width: 1000, height: 650)
    }
}
