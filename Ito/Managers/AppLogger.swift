import Foundation
import OSLog

public enum AppLogger {
    nonisolated(unsafe) private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ito.app"

    nonisolated(unsafe) public static let general = Logger(subsystem: subsystem, category: "general")
    nonisolated(unsafe) public static let network = Logger(subsystem: subsystem, category: "network")
    nonisolated(unsafe) public static let plugin = Logger(subsystem: subsystem, category: "plugin")
    nonisolated(unsafe) public static let database = Logger(subsystem: subsystem, category: "database")
    nonisolated(unsafe) public static let ui = Logger(subsystem: subsystem, category: "ui")
    nonisolated(unsafe) public static let auth = Logger(subsystem: subsystem, category: "auth")
    nonisolated(unsafe) public static let update = Logger(subsystem: subsystem, category: "update")
}
