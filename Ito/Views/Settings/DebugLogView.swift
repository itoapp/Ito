import SwiftUI
import OSLog
import Combine
import ito_runner

public struct LogEntry: Identifiable {
    public let id = UUID()
    public let date: Date
    public let subsystem: String
    public let category: String
    public let message: String
    public let type: OSLogEntryLog.Level
}

@MainActor
public class DebugLogViewModel: ObservableObject {
    @Published public var logs: [LogEntry] = []
    @Published public var isLoading = false
    @Published public var searchText = ""

    public init() {}

    public func fetchLogs() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                // Fetch logs from the last 24 hours
                let position = store.position(date: Date().addingTimeInterval(-86400))

                let entries = try store.getEntries(at: position)
                var fetchedLogs: [LogEntry] = []

                for entry in entries {
                    if let log = entry as? OSLogEntryLog {
                        // Filter to only our subsystems to avoid system noise
                        if log.subsystem == "moe.itoapp.ito" || log.subsystem == "moe.itoapp.runner" {
                            fetchedLogs.append(LogEntry(
                                date: log.date,
                                subsystem: log.subsystem,
                                category: log.category,
                                message: log.composedMessage,
                                type: log.level
                            ))
                        }
                    }
                }

                let reversed = Array(fetchedLogs.reversed())
                await MainActor.run {
                    self.logs = reversed
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    AppLogger.ui.error("Failed to fetch OSLog: \(error)")
                }
            }
        }
    }
}

public struct DebugLogView: View {
    @StateObject private var viewModel = DebugLogViewModel()

    public init() {}

    public var body: some View {
        List {
            if viewModel.isLoading && viewModel.logs.isEmpty {
                ProgressView("Fetching Logs...")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(filteredLogs) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(log.date, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(log.category)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(color(for: log.type).opacity(0.2))
                                .foregroundColor(color(for: log.type))
                                .cornerRadius(4)
                        }
                        Text(log.message)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .searchable(text: $viewModel.searchText)
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    viewModel.fetchLogs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let logText = viewModel.logs.map { "[\($0.date)] [\($0.category)] \($0.message)" }.joined(separator: "\n")
                    UIPasteboard.general.string = logText
                    SnackBarManager.shared.show(style: .success, title: "Copied to clipboard")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .onAppear {
            viewModel.fetchLogs()
        }
    }

    private var filteredLogs: [LogEntry] {
        if viewModel.searchText.isEmpty {
            return viewModel.logs
        }
        return viewModel.logs.filter {
            $0.message.localizedCaseInsensitiveContains(viewModel.searchText) ||
            $0.category.localizedCaseInsensitiveContains(viewModel.searchText)
        }
    }

    private func color(for level: OSLogEntryLog.Level) -> Color {
        switch level {
        case .fault, .error: return .red
        case .info, .notice: return .blue
        case .debug: return .gray
        default: return .primary
        }
    }
}
