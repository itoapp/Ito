import SwiftUI

public struct SharedDetailContent: View {
    public let isSaved: Bool
    public let isTracked: Bool
    public let tags: [String]?
    public let cleanDescription: String?
    public let onSaveToggle: () -> Void
    public let onTrackToggle: (() -> Void)?

    @State private var isDescriptionExpanded = false

    public init(isSaved: Bool, isTracked: Bool, tags: [String]?, cleanDescription: String?, onSaveToggle: @escaping () -> Void, onTrackToggle: (() -> Void)? = nil) {
        self.isSaved = isSaved
        self.isTracked = isTracked
        self.tags = tags
        self.cleanDescription = cleanDescription
        self.onSaveToggle = onSaveToggle
        self.onTrackToggle = onTrackToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            actionButtons.padding(.horizontal, 16).padding(.top, 16)

            if let tags = tags, !tags.isEmpty { tagsRow(tags: tags) }
            if let desc = cleanDescription, !desc.isEmpty { descriptionSection(desc) }

            Divider().padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(Color(.systemBackground))
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: onSaveToggle) {
                Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .tint(isSaved ? .blue : .secondary)
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if let onTrackToggle = onTrackToggle {
                Button(action: onTrackToggle) {
                    Label(isTracked ? "Tracking" : "Track", systemImage: isTracked ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .tint(isTracked ? .purple : .green)
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    private func tagsRow(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag).font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill)).cornerRadius(12)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.primary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .animation(.easeInOut(duration: 0.2), value: isDescriptionExpanded)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
            } label: {
                Text(isDescriptionExpanded ? "Show less" : "Show more")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16)
    }
}
