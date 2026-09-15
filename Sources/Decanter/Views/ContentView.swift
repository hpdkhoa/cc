import SwiftUI
import AppKit
import DecanterCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case library, runners, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "Library"
        case .runners: return "Runners"
        case .logs: return "Logs"
        }
    }
    var icon: String {
        switch self {
        case .library: return "gamecontroller"
        case .runners: return "shippingbox"
        case .logs: return "terminal"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarItem? = .library

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selection ?? .library {
            case .library: LibraryView()
            case .runners: RunnersView()
            case .logs: LogConsoleView()
            }
        }
        .frame(minWidth: 900, minHeight: 550)
        .alert("Rosetta 2 is required", isPresented: $state.showRosettaAlert) {
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Rosetta.installCommand, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Wine builds are Intel-only. Install Rosetta 2 in Terminal, then relaunch Decanter:\n\n\(Rosetta.installCommand)")
        }
        .alert(state.lastError?.title ?? "Error",
               isPresented: Binding(get: { state.lastError != nil }, set: { if !$0 { state.lastError = nil } }),
               presenting: state.lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { err in
            Text(err.message)
        }
    }
}
