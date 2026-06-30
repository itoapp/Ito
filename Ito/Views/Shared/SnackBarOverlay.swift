import SwiftUI
import Combine

public struct ToastMessage: Identifiable, Equatable {
    public let id = UUID()
    public enum Style {
        case success
        case error
        case info
    }
    public var style: Style
    public var title: String
    public var message: String?

    // For specific actions like 'Move' after saving
    public var actionId: String?
    public var actionTitle: String?
}

@MainActor
public class SnackBarManager: ObservableObject {
    public static let shared = SnackBarManager()

    @Published public var currentToast: ToastMessage?
    @Published public var isShowing: Bool = false

    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    public func show(style: ToastMessage.Style, title: String, message: String? = nil, actionTitle: String? = nil, actionId: String? = nil) {
        // Cancel any pending hide
        hideWorkItem?.cancel()

        let toast = ToastMessage(style: style, title: title, message: message, actionId: actionId, actionTitle: actionTitle)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            self.currentToast = toast
            self.isShowing = true
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    self?.isShowing = false
                }
            }
        }
        self.hideWorkItem = workItem
        // Errors stay a bit longer so user can read them
        let duration: TimeInterval = style == .error ? 4.5 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    public func showSaved(itemId: String) {
        show(style: .success, title: "Saved to Uncategorized", actionTitle: "Move", actionId: itemId)
    }

    public func showError(_ error: Error, title: String = "Error") {
        show(style: .error, title: title, message: error.localizedDescription)
    }

    public func showError(_ text: String, title: String = "Error") {
        show(style: .error, title: title, message: text)
    }
}

public struct SnackBarOverlay: View {
    @StateObject private var manager = SnackBarManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingSheetForId: String?

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear // Transparent root covering safe area
                .ignoresSafeArea()

            if manager.isShowing, let toast = manager.currentToast {
                HStack(spacing: 12) {
                    icon(for: toast.style)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if let msg = toast.message {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    if let actionTitle = toast.actionTitle, let actionId = toast.actionId {
                        Button {
                            showingSheetForId = actionId
                            withAnimation {
                                manager.isShowing = false
                            }
                        } label: {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                        }
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, 16)
                .padding(.trailing, toast.actionTitle != nil ? 8 : 16)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                .padding(.horizontal, 16)
                .transition(
                    reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
                )
                .id(toast.id) // Ensure transition triggers on change
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 10) // Floats above home indicator
        }
        .sheet(item: Binding(
            get: { showingSheetForId.map { SheetIdentifiable(id: $0) } },
            set: { showingSheetForId = $0?.id }
        )) { wrapper in
            CategoryAssignmentSheet(itemId: wrapper.id)
        }
    }

    @ViewBuilder
    private func icon(for style: ToastMessage.Style) -> some View {
        switch style {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
        }
    }
}

private struct SheetIdentifiable: Identifiable {
    let id: String
}
