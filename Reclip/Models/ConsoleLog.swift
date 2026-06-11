import Foundation
import SwiftUI

enum LogLevel {
    case info
    case warning
    case error
    case command
    case success

    var color: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .command: return .blue
        case .success: return .green
        }
    }

    var symbol: String {
        switch self {
        case .info: return "•"
        case .warning: return "⚠"
        case .error: return "✗"
        case .command: return "❯"
        case .success: return "✓"
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let level: LogLevel
    let message: String

    // DateFormatter is expensive to create — share one across all rows.
    // Only accessed from the main thread (console rendering + copy button).
    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }
}

@Observable
class ConsoleLog {
    static let shared = ConsoleLog()
    private init() {}

    var entries: [LogEntry] = []
    private let maxEntries = 1000

    func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(level: level, message: message)
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { self.append(entry) }
        }
    }

    private func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
