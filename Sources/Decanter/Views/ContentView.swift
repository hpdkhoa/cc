import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Library", systemImage: "gamecontroller")
                Label("Runners", systemImage: "shippingbox")
                Label("Recipes", systemImage: "doc.text")
            }
        } detail: {
            Text("Decanter — Phase 1 scaffold")
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
