import SwiftUI
import DecanterCore

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var showAddGame = false
    @State private var path: [UUID] = []

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if state.games.isEmpty {
                    ContentUnavailableView {
                        Label("No games yet", systemImage: "gamecontroller")
                    } description: {
                        Text(state.runners.isEmpty
                             ? "Install a Wine runner first (Runners tab), then add a local .exe."
                             : "Add a local Windows executable to get started.")
                    } actions: {
                        Button("Add Game…") { showAddGame = true }.disabled(state.runners.isEmpty)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(state.games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { game in
                                NavigationLink(value: game.id) {
                                    GameCard(game: game, running: state.isRunning(game))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if state.isRunning(game) {
                                        Button("Stop") { Task { await state.stop(game) } }
                                    } else {
                                        Button("Launch") { Task { await state.launch(game) } }
                                    }
                                    Divider()
                                    Button("Remove from Library", role: .destructive) { state.remove(game) }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { id in
                if let game = state.game(id: id) {
                    GameDetailView(gameID: game.id)
                } else {
                    ContentUnavailableView("Game removed", systemImage: "trash")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddGame = true } label: { Label("Add Game", systemImage: "plus") }
                        .disabled(state.runners.isEmpty)
                        .help(state.runners.isEmpty ? "Install a runner first" : "Add a local .exe")
                }
            }
            .sheet(isPresented: $showAddGame) {
                AddGameView { newGame in
                    state.add(newGame)
                    path = [newGame.id]
                }
            }
        }
    }
}

struct GameCard: View {
    let game: Game
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                Image(systemName: "app.dashed").font(.system(size: 40)).foregroundStyle(.secondary)
                if running {
                    VStack { HStack { Spacer(); Circle().fill(.green).frame(width: 10, height: 10).padding(8) }; Spacer() }
                }
            }
            .aspectRatio(1.5, contentMode: .fit)
            Text(game.name).font(.headline).lineLimit(1)
            Text(game.prefixName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if game.playtimeSeconds > 0 {
                Text(Playtime.format(game.playtimeSeconds)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background).shadow(radius: 1))
    }
}

enum Playtime {
    static func format(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s played" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m played" : "\(m)m played"
    }
}
