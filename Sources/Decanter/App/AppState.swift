import SwiftUI
import DecanterCore

struct AppError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Main-actor UI state. Talks to the Core actors and mirrors their results.
@MainActor @Observable
final class AppState {
    var games: [Game] = []
    var runners: [Runner] = []
    var prefixes: [WinePrefix] = []
    var defaultRunnerID: String?
    var runningGameIDs: Set<UUID> = []
    var rosetta: Rosetta.Status = .notNeeded
    var showRosettaAlert = false
    var lastError: AppError?

    let runnerManager = RunnerManager()
    let prefixManager = PrefixManager()
    let launcher = Launcher()

    // MARK: Lifecycle

    func bootstrap() async {
        do { try Paths.bootstrap() } catch { report(error, title: "Cannot create data directory") }
        Log.shared.info("app", "data dir: \(Paths.dataDir.path)")
        Log.shared.info("app", "vendor dir: \(Paths.vendorDir?.path ?? "not found")")
        rosetta = await Rosetta.check()
        Log.shared.info("app", "rosetta: \(rosetta)")
        showRosettaAlert = rosetta == .missing
        await refresh()
    }

    func refresh() async {
        runners = await runnerManager.installed()
        prefixes = await prefixManager.list()
        defaultRunnerID = Settings.load().defaultRunnerID ?? runners.first?.id
        loadLibrary()
    }

    func report(_ error: Error, title: String = "Error") {
        Log.shared.error("app", "\(title): \(error.localizedDescription)")
        lastError = AppError(title: title, message: error.localizedDescription)
    }

    // MARK: Library

    func loadLibrary() {
        do { games = try LibraryStore.load() } catch { report(error, title: "Cannot read library.json") }
    }

    func saveLibrary() {
        do { try LibraryStore.save(games) } catch { report(error, title: "Cannot write library.json") }
    }

    func add(_ game: Game) {
        games.append(game)
        saveLibrary()
        Log.shared.info("library", "added \(game.name)")
    }

    func update(_ game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i] = game
        saveLibrary()
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        saveLibrary()
        Log.shared.info("library", "removed \(game.name)")
    }

    func game(id: UUID) -> Game? { games.first { $0.id == id } }
    func runner(id: String) -> Runner? { runners.first { $0.id == id } }
    func runner(for game: Game) -> Runner? { runner(id: game.runnerID) ?? defaultRunner }
    func prefix(for game: Game) -> WinePrefix? { prefixes.first { $0.name == game.prefixName } }
    var defaultRunner: Runner? { runners.first { $0.id == defaultRunnerID } ?? runners.first }

    // MARK: Launch / stop

    func isRunning(_ game: Game) -> Bool { runningGameIDs.contains(game.id) }

    func launch(_ game: Game) async {
        guard let runner = runner(for: game) else {
            report(RunnerError.notInstalled(game.runnerID), title: "Cannot launch \(game.name)"); return
        }
        guard let prefix = prefix(for: game) else {
            report(PrefixError.notFound(game.prefixName), title: "Cannot launch \(game.name)"); return
        }
        let id = game.id
        // Mark running before spawning: a process that dies instantly fires onExit
        // before launch() returns, and the remove must not race the insert.
        runningGameIDs.insert(id)
        do {
            try await launcher.launch(game: game, prefix: prefix, runner: runner) { [weak self] _, seconds in
                await MainActor.run {
                    guard let self else { return }
                    self.runningGameIDs.remove(id)
                    if var g = self.game(id: id) {
                        g.playtimeSeconds += seconds
                        g.lastPlayed = Date()
                        self.update(g)
                    }
                }
            }
        } catch {
            runningGameIDs.remove(id)
            report(error, title: "Cannot launch \(game.name)")
        }
    }

    func stop(_ game: Game) async {
        guard let runner = runner(for: game), let prefix = prefix(for: game) else { return }
        do { try await launcher.stop(game: game, prefix: prefix, runner: runner) }
        catch { report(error, title: "Cannot stop \(game.name)") }
    }
}
