import Foundation
import OSLog

nonisolated enum DebugLogLevel: Equatable, Sendable {
    case fault
    case error
    case info
    case notice
    case debug
    case other
}

nonisolated struct DebugLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let subsystem: String
    let category: String
    let message: String
    let level: DebugLogLevel

    init(
        id: UUID = UUID(),
        date: Date,
        subsystem: String,
        category: String,
        message: String,
        level: DebugLogLevel
    ) {
        self.id = id
        self.date = date
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.level = level
    }
}

nonisolated protocol DebugLogReading: Sendable {
    func readEntries(
        lookback: TimeInterval,
        allowedSubsystems: Set<String>
    ) async throws -> [DebugLogEntry]
}

actor SystemDebugLogReader: DebugLogReading {
    func readEntries(
        lookback: TimeInterval,
        allowedSubsystems: Set<String>
    ) async throws -> [DebugLogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-lookback))
        return try store.getEntries(at: position).compactMap { entry in
            guard let log = entry as? OSLogEntryLog,
                  allowedSubsystems.contains(log.subsystem) else {
                return nil
            }
            return DebugLogEntry(
                date: log.date,
                subsystem: log.subsystem,
                category: log.category,
                message: log.composedMessage,
                level: Self.level(for: log.level)
            )
        }
    }

    private static func level(for level: OSLogEntryLog.Level) -> DebugLogLevel {
        switch level {
        case .fault:
            return .fault
        case .error:
            return .error
        case .info:
            return .info
        case .notice:
            return .notice
        case .debug:
            return .debug
        default:
            return .other
        }
    }
}
