import Foundation

/// One line in the log console.
public struct LogEntry: Identifiable, Hashable, Sendable {
    public enum Level: String, Sendable, Hashable {
        case info, command, output, error
    }
    public let id: UUID
    public let date: Date
    public let source: String
    public let level: Level
    public let message: String

    public init(date: Date = Date(), source: String, level: Level, message: String) {
        self.id = UUID()
        self.date = date
        self.source = source
        self.level = level
        self.message = message
    }
}

/// Process-wide log. Every external command (argv + env diff) and every line of
/// output goes through here; the LogConsole view subscribes to `stream()`.
/// Thread-safe: writes come from pipe-reader threads, reads from the main actor.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public var maxEntries = 20_000

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var subscribers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]

    /// Mirror every entry to stderr (`DECANTER_LOG_STDERR=1`), handy for `swift run` and tests.
    public var echoToStderr = ProcessInfo.processInfo.environment["DECANTER_LOG_STDERR"] == "1"

    public init() {}

    public func write(_ entry: LogEntry) {
        if echoToStderr {
            FileHandle.standardError.write("[\(entry.source)] \(entry.message)\n".data(using: .utf8)!)
        }
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        let subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { s.yield(entry) }
    }

    public func info(_ source: String, _ message: String)    { write(LogEntry(source: source, level: .info, message: message)) }
    public func command(_ source: String, _ message: String) { write(LogEntry(source: source, level: .command, message: message)) }
    public func output(_ source: String, _ message: String)  { write(LogEntry(source: source, level: .output, message: message)) }
    public func error(_ source: String, _ message: String)   { write(LogEntry(source: source, level: .error, message: message)) }

    public func snapshot() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    /// Live stream of entries. With `includingHistory` the existing entries are
    /// delivered first, atomically with the subscription, so nothing is missed.
    public func stream(includingHistory: Bool = true) -> AsyncStream<LogEntry> {
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        lock.lock()
        if includingHistory { for e in entries { continuation.yield(e) } }
        subscribers[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
        }
        return stream
    }
}
