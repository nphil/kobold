import Foundation

#if canImport(OSLog)
import OSLog
#endif

/// Writes to the system log, so entries show up in Console.app and in Xcode
/// without any configuration.
///
/// On platforms without OSLog this falls back to stdout, which keeps the module
/// usable in tests and on Linux CI.
public struct ConsoleSink: LogSink {

    #if canImport(OSLog)
    private let loggers: [LogCategory: os.Logger]
    #endif

    public init(subsystem: String = "com.nphil.kobold") {
        #if canImport(OSLog)
        var built: [LogCategory: os.Logger] = [:]
        for category in LogCategory.allCases {
            built[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
        }
        loggers = built
        #endif
    }

    public func write(_ entry: LogEntry) {
        #if canImport(OSLog)
        guard let logger = loggers[entry.category] else { return }
        // Interpolated as public: these are diagnostics for the developer's own
        // device, and redacting them would defeat the purpose.
        switch entry.level {
        case .debug: logger.debug("\(entry.message, privacy: .public)")
        case .info: logger.info("\(entry.message, privacy: .public)")
        case .warning: logger.warning("\(entry.message, privacy: .public)")
        case .error: logger.error("\(entry.message, privacy: .public)")
        }
        #else
        print(entry.formatted)
        #endif
    }
}
