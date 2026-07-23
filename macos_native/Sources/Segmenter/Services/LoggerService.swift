import Foundation
import os

public final class LoggerService {
    public static let shared = LoggerService()

    private let osLogger = Logger(subsystem: "org.theintrodb.segmenter", category: "App")
    private let dateFormatter: DateFormatter

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    public enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"

        var colorCode: String {
            switch self {
            case .debug: return "\u{001B}[36m" // Cyan
            case .info:  return "\u{001B}[32m" // Green
            case .warn:  return "\u{001B}[33m" // Yellow
            case .error: return "\u{001B}[31m" // Red
            }
        }

        var resetCode: String { "\u{001B}[0m" }
    }

    public func log(_ message: String, level: Level = .info, file: String = #file, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let filename = (file as NSString).lastPathComponent
        let formattedConsoleMsg = "\(timestamp) [\(level.colorCode)\(level.rawValue)\(level.resetCode)] [\(filename):\(line)] \(message)"

        // Print to Terminal stdout/stderr
        if level == .error {
            fputs("\(formattedConsoleMsg)\n", stderr)
        } else {
            print(formattedConsoleMsg)
        }

        // Send to Apple Unified OSLog system
        switch level {
        case .debug:
            osLogger.debug("[\(filename):\(line)] \(message, privacy: .public)")
        case .info:
            osLogger.info("[\(filename):\(line)] \(message, privacy: .public)")
        case .warn:
            osLogger.warning("[\(filename):\(line)] \(message, privacy: .public)")
        case .error:
            osLogger.error("[\(filename):\(line)] \(message, privacy: .public)")
        }
    }

    public func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .debug, file: file, line: line)
    }

    public func info(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .info, file: file, line: line)
    }

    public func warn(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .warn, file: file, line: line)
    }

    public func error(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .error, file: file, line: line)
    }
}
