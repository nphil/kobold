import Foundation

public enum LogLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    /// Emoji tag, used by remote sinks where a glanceable marker is worth more
    /// than a word.
    public var tag: String {
        switch self {
        case .debug: return "mag"
        case .info: return "information_source"
        case .warning: return "warning"
        case .error: return "rotating_light"
        }
    }
}

/// Where a message came from. Kept as a small closed set so filtering is
/// predictable rather than depending on free-form strings.
public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case transport
    case elm327
    case decode
    case session
    case ui
    case app
}

public struct LogEntry: Sendable, Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public init(id: UUID = UUID(),
                date: Date = Date(),
                level: LogLevel,
                category: LogCategory,
                message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    /// `12:34:56.789  WARN  elm327  message`
    public var formatted: String {
        "\(Self.timeFormatter.string(from: date))  \(level.label)  \(category.rawValue)  \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// A destination for log entries.
///
/// Sinks must never block the caller: logging sits on paths that run hundreds of
/// times a second, and a sink that waits on the network would become the
/// performance problem it was added to diagnose.
public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}

/// The app's logger.
///
/// An actor rather than a lock so that a call from any isolation domain is
/// cheap and non-blocking, and so the in-memory buffer has exactly one owner.
public actor Logger {

    public static let shared = Logger()

    private var sinks: [LogSink] = []
    private var buffer: [LogEntry] = []
    private let bufferLimit: Int

    /// Entries below this are dropped before reaching any sink.
    public private(set) var minimumLevel: LogLevel = .debug

    public init(bufferLimit: Int = 500) {
        self.bufferLimit = bufferLimit
    }

    public func add(sink: LogSink) {
        sinks.append(sink)
    }

    public func removeAllSinks() {
        sinks.removeAll()
    }

    public func setMinimumLevel(_ level: LogLevel) {
        minimumLevel = level
    }

    /// Recent entries, oldest first — the backing for an in-app log view and for
    /// attaching context to a bug report.
    public func recent(limit: Int = 200) -> [LogEntry] {
        Array(buffer.suffix(limit))
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        guard level >= minimumLevel else { return }

        let entry = LogEntry(level: level, category: category, message: message)

        buffer.append(entry)
        if buffer.count > bufferLimit {
            buffer.removeFirst(buffer.count - bufferLimit)
        }

        for sink in sinks {
            sink.write(entry)
        }
    }
}

/// Fire-and-forget entry points.
///
/// Deliberately non-async so a caller on a hot path never has to await, and
/// never has to care which isolation domain it is in. The cost at the call site
/// is spawning a task; the work happens on the logger's actor.
public enum Log {

    public static func debug(_ category: LogCategory, _ message: @autoclosure @escaping @Sendable () -> String) {
        emit(.debug, category, message)
    }

    public static func info(_ category: LogCategory, _ message: @autoclosure @escaping @Sendable () -> String) {
        emit(.info, category, message)
    }

    public static func warning(_ category: LogCategory, _ message: @autoclosure @escaping @Sendable () -> String) {
        emit(.warning, category, message)
    }

    public static func error(_ category: LogCategory, _ message: @autoclosure @escaping @Sendable () -> String) {
        emit(.error, category, message)
    }

    private static func emit(_ level: LogLevel,
                             _ category: LogCategory,
                             _ message: @escaping @Sendable () -> String) {
        // The message is an autoclosure so building the string is skipped
        // entirely when the entry would be filtered out.
        Task.detached(priority: .utility) {
            await Logger.shared.log(level, category, message())
        }
    }
}
