import Foundation

public enum LaunchError: Error, LocalizedError, Sendable {
    case exeMissing(URL)
    case alreadyRunning(String)

    public var errorDescription: String? {
        switch self {
        case .exeMissing(let url): return "Executable not found: \(url.path)"
        case .alreadyRunning(let name): return "\(name) is already running."
        }
    }
}

/// Starts games inside their prefix, tracks the wine process, and stops them with
/// `wineserver -k` (which kills every Windows process in the prefix).
public actor Launcher {
    public struct Session: Sendable {
        public let gameID: UUID
        public let process: RunningProcess
        public let startedAt: Date
    }

    private var sessions: [UUID: Session] = [:]

    public init() {}

    public func isRunning(_ gameID: UUID) -> Bool {
        guard let s = sessions[gameID] else { return false }
        return s.process.isRunning
    }

    public func session(for gameID: UUID) -> Session? { sessions[gameID] }

    /// Spawn `wine <exe> <args>` with cwd = the exe's folder. `onExit` receives the
    /// exit code and elapsed seconds once the wine process ends.
    @discardableResult
    public func launch(game: Game, prefix: WinePrefix, runner: Runner,
                       onExit: (@Sendable (Int32, Int) async -> Void)? = nil) throws -> RunningProcess {
        if isRunning(game.id) { throw LaunchError.alreadyRunning(game.name) }
        let exe = game.resolvedExe(in: prefix)
        guard FileManager.default.fileExists(atPath: exe.path) else { throw LaunchError.exeMissing(exe) }

        let spec = WineProcess.wine(runner: runner, prefix: prefix.url, arguments: [exe.path] + game.args,
                                    env: game.env, currentDirectory: exe.deletingLastPathComponent(),
                                    label: "game:\(game.name)")
        Log.shared.info("launcher", "launching \(game.name) in prefix \(prefix.name) with \(runner.id)")
        let process = try WineProcess.spawn(spec)
        let session = Session(gameID: game.id, process: process, startedAt: Date())
        sessions[game.id] = session

        Task { [weak self] in
            let code = await process.waitUntilExit()
            let seconds = Int(Date().timeIntervalSince(session.startedAt))
            await self?.forget(game.id, process: process)
            Log.shared.info("launcher", "\(game.name) ended (code \(code)) after \(seconds)s")
            await onExit?(code, seconds)
        }
        return process
    }

    private func forget(_ gameID: UUID, process: RunningProcess) {
        if let s = sessions[gameID], s.process === process { sessions[gameID] = nil }
    }

    /// `wineserver -k` for the prefix, then SIGTERM the tracked wine process if still alive.
    public func stop(game: Game, prefix: WinePrefix, runner: Runner) async throws {
        Log.shared.info("launcher", "stopping \(game.name)")
        try await WineProcess.run(WineProcess.wineserver(runner: runner, prefix: prefix.url, arguments: ["-k"]), check: false)
        if let s = sessions[game.id], s.process.isRunning {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if s.process.isRunning { s.process.terminate() }
        }
    }

    /// Kill everything in a prefix regardless of which game started it.
    public func killPrefix(_ prefix: WinePrefix, runner: Runner) async throws {
        try await WineProcess.run(WineProcess.wineserver(runner: runner, prefix: prefix.url, arguments: ["-k"]), check: false)
    }

    /// `wine start <target>` — opens a URL (custom scheme via HKCR), a file, or a program
    /// through ShellExecute. Used to test URL-scheme handlers registered in the prefix.
    @discardableResult
    public func start(_ target: String, prefix: WinePrefix, runner: Runner, env: [String: String] = [:]) throws -> RunningProcess {
        Log.shared.info("launcher", "wine start \(target)")
        return try WineProcess.spawn(WineProcess.wine(runner: runner, prefix: prefix.url, arguments: ["start", target],
                                                      env: env, label: "start"))
    }
}
