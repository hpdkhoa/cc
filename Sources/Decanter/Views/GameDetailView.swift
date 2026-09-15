import SwiftUI
import AppKit
import DecanterCore

@MainActor struct GameDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID

    @State private var winetricksVerbs = ""
    @State private var startTarget = ""
    @State private var busy: String?
    @State private var confirmRemove = false

    private var game: Game? { state.game(id: gameID) }

    var body: some View {
        if let game {
            let prefix = state.prefix(for: game)
            let runner = state.runner(for: game)
            let running = state.isRunning(game)
            VSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name).font(.largeTitle).bold()
                                Text(game.exePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack(spacing: 12) {
                                    Label(prefix?.name ?? game.prefixName + " (missing)", systemImage: "folder")
                                    Label(runner?.displayName ?? game.runnerID + " (missing)", systemImage: "shippingbox")
                                    if let w = prefix?.windowsVersion { Label(w.displayName, systemImage: "pc") }
                                }
                                .font(.callout).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Text(Playtime.format(game.playtimeSeconds))
                                    if let last = game.lastPlayed { Text("Last played \(last.formatted(date: .abbreviated, time: .shortened))") }
                                }
                                .font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if running {
                                Button(role: .destructive) { Task { await state.stop(game) } } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                }
                                .controlSize(.large)
                            } else {
                                Button { Task { await state.launch(game) } } label: {
                                    Label("Launch", systemImage: "play.fill")
                                }
                                .controlSize(.large).buttonStyle(.borderedProminent)
                                .disabled(prefix == nil || runner == nil)
                            }
                        }

                        GroupBox("Prefix tools") {
                            HStack {
                                Button("Reveal Prefix") { if let p = prefix { NSWorkspace.shared.activateFileViewerSelecting([p.driveC]) } }
                                ForEach(WineTool.allCases, id: \.self) { tool in
                                    Button(tool.displayName) { openTool(tool, game: game) }
                                }
                                Spacer()
                                Button("Kill all in prefix", role: .destructive) { Task { await killPrefix(game) } }
                            }
                            .disabled(prefix == nil || runner == nil)
                        }

                        GroupBox("winetricks") {
                            HStack {
                                TextField("verbs, e.g. corefonts vcrun2010", text: $winetricksVerbs)
                                    .onSubmit { Task { await runWinetricks(game) } }
                                Button("Run") { Task { await runWinetricks(game) } }
                                    .disabled(winetricksVerbs.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
                            }
                            .disabled(prefix == nil || runner == nil)
                        }

                        GroupBox("Run inside prefix (wine start)") {
                            HStack {
                                TextField("URL, file or program, e.g. gamename://launch", text: $startTarget)
                                    .onSubmit { Task { await start(game) } }
                                Button("Start") { Task { await start(game) } }
                                    .disabled(startTarget.isEmpty || busy != nil)
                            }
                            .disabled(prefix == nil || runner == nil)
                            Text("Tests URL-scheme handlers registered under HKEY_CLASSES_ROOT in this prefix.")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let busy {
                            HStack { ProgressView().controlSize(.small); Text(busy).font(.callout).foregroundStyle(.secondary) }
                        }

                        HStack {
                            Spacer()
                            Button("Remove from Library", role: .destructive) { confirmRemove = true }
                        }
                    }
                    .padding()
                }
                .frame(minHeight: 260)

                LogConsoleView(title: "Log")
                    .frame(minHeight: 150)
            }
            .navigationTitle(game.name)
            .confirmationDialog("Remove \(game.name) from the library?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { state.remove(game); dismiss() }
            } message: {
                Text("The prefix and its files are kept on disk.")
            }
        } else {
            ContentUnavailableView("Game removed", systemImage: "trash")
        }
    }

    private func openTool(_ tool: WineTool, game: Game) {
        guard let p = state.prefix(for: game), let r = state.runner(for: game) else { return }
        Task {
            do { try await state.prefixManager.open(tool: tool, prefix: p, runner: r) }
            catch { state.report(error, title: "Cannot open \(tool.displayName)") }
        }
    }

    private func killPrefix(_ game: Game) async {
        guard let p = state.prefix(for: game), let r = state.runner(for: game) else { return }
        do { try await state.launcher.killPrefix(p, runner: r) } catch { state.report(error, title: "wineserver -k failed") }
    }

    private func runWinetricks(_ game: Game) async {
        guard let p = state.prefix(for: game), let r = state.runner(for: game) else { return }
        let verbs = winetricksVerbs.split(separator: " ").map(String.init)
        busy = "winetricks \(verbs.joined(separator: " "))…"
        defer { busy = nil }
        do {
            try await state.prefixManager.winetricks(verbs: verbs, prefix: p, runner: r)
            winetricksVerbs = ""
        } catch {
            state.report(error, title: "winetricks failed")
        }
    }

    private func start(_ game: Game) async {
        guard let p = state.prefix(for: game), let r = state.runner(for: game) else { return }
        do { try await state.launcher.start(startTarget, prefix: p, runner: r, env: game.env) }
        catch { state.report(error, title: "wine start failed") }
    }
}
