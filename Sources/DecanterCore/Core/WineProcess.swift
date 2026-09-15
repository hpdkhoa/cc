import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Description of one external command. Environment entries are applied on top of
/// the inherited environment; only the differences are logged.
public struct CommandSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?
    /// Name shown as the log source ("wine", "wineserver", "tar", ...).
    public var label: String

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:],
                currentDirectory: URL? = nil, label: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.label = label ?? executable.lastPathComponent
    }

    public init(path: String, arguments: [String] = [], environment: [String: String] = [:],
                currentDirectory: URL? = nil, label: String? = nil) {
        self.init(executable: URL(fileURLWithPath: path), arguments: arguments, environment: environment,
                  currentDirectory: currentDirectory, label: label)
    }

    /// Shell-quoted argv for the log.
    public var commandLine: String {
        ([executable.path] + arguments).map(CommandSpec.shellQuote).joined(separator: " ")
    }

    /// Environment entries that differ from the current process environment.
    public var environmentDiff: [String: String] {
        let base = ProcessInfo.processInfo.environment
        return environment.filter { base[$0.key] != $0.value }
    }

    public static func shellQuote(_ s: String) -> String {
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:,+@%".contains($0) }
        if !s.isEmpty && safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct CommandResult: Sendable {
    public let spec: CommandSpec
    public let exitCode: Int32
    public let output: [String]
    public var succeeded: Bool { exitCode == 0 }
    public var outputText: String { output.joined(separator: "\n") }
}

public struct CommandError: Error, LocalizedError, Sendable {
    public let spec: CommandSpec
    public let exitCode: Int32
    public let outputTail: [String]

    public var errorDescription: String? {
        let tail = outputTail.suffix(8).joined(separator: "\n")
        return "\(spec.label) exited with code \(exitCode)" + (tail.isEmpty ? "" : ":\n\(tail)")
    }
}

/// A spawned process: live merged stdout+stderr lines, exit code, kill switch.
public final class RunningProcess: @unchecked Sendable {
    public let spec: CommandSpec
    public let startedAt = Date()
    /// Merged stdout+stderr, one element per line. Finishes at EOF.
    public let output: AsyncStream<String>

    private let process: Process
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    fileprivate init(spec: CommandSpec, process: Process, output: AsyncStream<String>) {
        self.spec = spec
        self.process = process
        self.output = output
    }

    public var pid: Int32 { process.processIdentifier }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitCode == nil
    }

    fileprivate func markExited(_ code: Int32) {
        lock.lock()
        exitCode = code
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pending { w.resume(returning: code) }
    }

    public func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                c.resume(returning: code)
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    /// SIGTERM.
    public func terminate() {
        guard isRunning else { return }
        process.terminate()
    }

    /// SIGKILL.
    public func kill() {
        guard isRunning else { return }
        #if canImport(Glibc) || canImport(Darwin)
        _ = Foundation.kill(pid, SIGKILL)
        #else
        process.terminate()
        #endif
    }
}

/// The single place Decanter spawns external processes. Wine/wineserver/winetricks
/// invocations are built with the helpers below; nothing else creates a `Process`.
public enum WineProcess {

    // MARK: Spawning

    /// Start a command. Its argv and env diff are logged immediately, every output
    /// line is logged as it arrives, and the exit code is logged on termination.
    public static func spawn(_ spec: CommandSpec) throws -> RunningProcess {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment { env[k] = v }
        process.environment = env
        if let cwd = spec.currentDirectory { process.currentDirectoryURL = cwd }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        let lines = LineBuffer()
        let label = spec.label
        let log = Log.shared

        // Blocking read loop on a background thread: deterministic EOF on both
        // Darwin and corelibs-foundation (readabilityHandler is unreliable at EOF on Linux).
        let reader = pipe.fileHandleForReading
        let readQueue = DispatchQueue(label: "decanter.process.\(label)", qos: .utility)
        readQueue.async {
            while true {
                let data = (try? reader.read(upToCount: 65_536)) ?? nil
                guard let data, !data.isEmpty else { break }
                for line in lines.append(data) {
                    log.output(label, line)
                    continuation.yield(line)
                }
            }
            for line in lines.flush() {
                log.output(label, line)
                continuation.yield(line)
            }
            continuation.finish()
            try? reader.close()
        }

        let diff = spec.environmentDiff
        let basePath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let envText = diff.keys.sorted().map { key -> String in
            var value = diff[key] ?? ""
            // PATH is always "runner bin + inherited PATH"; keep the log readable.
            if key == "PATH", !basePath.isEmpty, value.hasSuffix(":" + basePath) {
                value = String(value.dropLast(basePath.count)) + "$PATH"
            }
            return "\(key)=\(CommandSpec.shellQuote(value))"
        }.joined(separator: " ")
        log.command(label, "$ " + (envText.isEmpty ? "" : envText + " ") + spec.commandLine
                    + (spec.currentDirectory.map { "   (cwd: \($0.path))" } ?? ""))

        let running = RunningProcess(spec: spec, process: process, output: stream)
        process.terminationHandler = { p in
            let code = p.terminationStatus
            if code == 0 {
                log.info(label, "exited with code 0")
            } else {
                log.error(label, "exited with code \(code)")
            }
            running.markExited(code)
        }

        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()   // child holds its own copy; EOF arrives when it exits
        } catch {
            try? pipe.fileHandleForWriting.close()   // unblocks the reader, which finishes the stream
            log.error(label, "failed to start \(spec.executable.path): \(error.localizedDescription)")
            throw error
        }
        return running
    }

    /// Run to completion, collecting all output. Throws `CommandError` on a non-zero
    /// exit when `check` is true.
    @discardableResult
    public static func run(_ spec: CommandSpec, check: Bool = true) async throws -> CommandResult {
        let proc = try spawn(spec)
        var output: [String] = []
        for await line in proc.output { output.append(line) }
        let code = await proc.waitUntilExit()
        if check && code != 0 {
            throw CommandError(spec: spec, exitCode: code, outputTail: Array(output.suffix(20)))
        }
        return CommandResult(spec: spec, exitCode: code, output: output)
    }

    // MARK: Wine command builders

    /// Environment for running anything inside `prefix` with `runner`.
    public static func wineEnvironment(runner: Runner, prefix: URL, extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all",
            "WINE": runner.wine.path,
            "WINESERVER": runner.wineserver.path,
            "PATH": runner.binDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
        ]
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// `wine <arguments>` inside a prefix.
    public static func wine(runner: Runner, prefix: URL, arguments: [String], env: [String: String] = [:],
                            currentDirectory: URL? = nil, label: String = "wine") -> CommandSpec {
        CommandSpec(executable: runner.wine, arguments: arguments,
                    environment: wineEnvironment(runner: runner, prefix: prefix, extra: env),
                    currentDirectory: currentDirectory, label: label)
    }

    /// `wineserver <arguments>` (e.g. `-k` to kill everything in the prefix, `-w` to wait).
    public static func wineserver(runner: Runner, prefix: URL, arguments: [String]) -> CommandSpec {
        CommandSpec(executable: runner.wineserver, arguments: arguments,
                    environment: wineEnvironment(runner: runner, prefix: prefix), label: "wineserver")
    }

    /// `sh winetricks --unattended <verbs>` with the runner's wine on PATH.
    public static func winetricks(script: URL, runner: Runner, prefix: URL, verbs: [String]) -> CommandSpec {
        CommandSpec(path: "/bin/sh", arguments: [script.path, "--unattended"] + verbs,
                    environment: wineEnvironment(runner: runner, prefix: prefix, extra: ["WINETRICKS_LATEST_VERSION_CHECK": "disabled"]),
                    label: "winetricks")
    }
}

/// Splits a byte stream into lines. Thread-confined to the pipe reader queue.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return [line]
    }
}
