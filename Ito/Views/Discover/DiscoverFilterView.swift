import SwiftUI

struct DiscoverFilterView: View {
    let mediaType: DiscoverMediaType
    @Binding var filters: DiscoverFilters
    var onApply: () -> Void
    var onReset: () -> Void

    @StateObject private var manager = DiscoverManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var localFilters: DiscoverFilters = DiscoverFilters()
    @State private var expandedTagCategories: Set<String> = []

    private var animeFormats: [(String, String)] {
        [("TV", "TV"), ("TV_SHORT", "TV Short"), ("MOVIE", "Movie"),
         ("SPECIAL", "Special"), ("OVA", "OVA"), ("ONA", "ONA"), ("MUSIC", "Music")]
    }

    private var mangaFormats: [(String, String)] {
        [("MANGA", "Manga"), ("ONE_SHOT", "One Shot"), ("NOVEL", "Novel")]
    }

    private var formats: [(String, String)] {
        mediaType == .anime ? animeFormats : mangaFormats
    }

    private let statuses: [(String, String)] = [
        ("RELEASING", "Releasing"), ("FINISHED", "Finished"),
        ("NOT_YET_RELEASED", "Upcoming"), ("CANCELLED", "Cancelled"), ("HIATUS", "Hiatus")
    ]

    private let countries: [(String, String)] = [
        ("JP", "Japan"), ("KR", "South Korea"), ("CN", "China"), ("TW", "Taiwan")
    ]

    private var groupedTags: [(String, [DiscoverTag])] {
        let nonAdult = manager.availableTags.filter { $0.isAdult != true }
        let grouped = Dictionary(grouping: nonAdult) { $0.category ?? "Other" }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationView {
            List {
                sortSection
                genreSection
                formatSection
                statusSection
                countrySection
                tagSection
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") {
                        localFilters = DiscoverFilters()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        filters = localFilters
                        onApply()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .onAppear {
                localFilters = filters
                if manager.availableGenres.isEmpty {
                    Task { await manager.loadGenresAndTags() }
                }
            }
        }
        .interactiveDismissDisabled(localFilters != filters)
    }

    // MARK: - Sort

    private var sortSection: some View {
        Section("Sort By") {
            Picker("Sort By", selection: $localFilters.sort) {
                ForEach([DiscoverSort.trending, .popularity, .score, .newest], id: \.self) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    // MARK: - Genres

    private var genreSection: some View {
        Section {
            if manager.availableGenres.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                WrappingHStack(items: manager.availableGenres) { genre in
                    let isSelected = localFilters.genres.contains(genre)
                    Button {
                        if isSelected {
                            localFilters.genres.removeAll { $0 == genre }
                        } else {
                            localFilters.genres.append(genre)
                        }
                    } label: {
                        Text(genre)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                            .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
                            .foregroundColor(isSelected ? .white : .primary)
                            .cornerRadius(14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("Genres")
                if !localFilters.genres.isEmpty {
                    Text("(\(localFilters.genres.count))")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Format

    private var formatSection: some View {
        Section("Format") {
            ForEach(formats, id: \.0) { value, label in
                Button {
                    localFilters.format = localFilters.format == value ? nil : value
                } label: {
                    HStack {
                        Text(label).foregroundColor(.primary)
                        Spacer()
                        if localFilters.format == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .accessibilityAddTraits(localFilters.format == value ? .isSelected : [])
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            ForEach(statuses, id: \.0) { value, label in
                Button {
                    localFilters.status = localFilters.status == value ? nil : value
                } label: {
                    HStack {
                        Text(label).foregroundColor(.primary)
                        Spacer()
                        if localFilters.status == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .accessibilityAddTraits(localFilters.status == value ? .isSelected : [])
            }
        }
    }

    // MARK: - Country

    private var countrySection: some View {
        Section("Country") {
            ForEach(countries, id: \.0) { value, label in
                Button {
                    localFilters.countryOfOrigin = localFilters.countryOfOrigin == value ? nil : value
                } label: {
                    HStack {
                        Text(label).foregroundColor(.primary)
                        Spacer()
                        if localFilters.countryOfOrigin == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .accessibilityAddTraits(localFilters.countryOfOrigin == value ? .isSelected : [])
            }
        }
    }

    // MARK: - Tags

    private var tagSection: some View {
        Section {
            if manager.availableTags.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                ForEach(groupedTags, id: \.0) { category, tags in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedTagCategories.contains(category) },
                            set: { expanded in
                                if expanded {
                                    expandedTagCategories.insert(category)
                                } else {
                                    expandedTagCategories.remove(category)
                                }
                            }
                        )
                    ) {
                        WrappingHStack(items: tags) { tag in
                            let isSelected = localFilters.tags.contains(tag.name)
                            Button {
                                if isSelected {
                                    localFilters.tags.removeAll { $0 == tag.name }
                                } else {
                                    localFilters.tags.append(tag.name)
                                }
                            } label: {
                                Text(tag.name)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .frame(minHeight: 44)
                                    .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
                                    .foregroundColor(isSelected ? .white : .primary)
                                    .cornerRadius(14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        HStack {
                            Text(category)
                                .foregroundColor(.primary)
                            let selectedCount = tags.filter { localFilters.tags.contains($0.name) }.count
                            if selectedCount > 0 {
                                Text("(\(selectedCount))")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Tags")
                if !localFilters.tags.isEmpty {
                    Text("(\(localFilters.tags.count))")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

// MARK: - Wrapping HStack (iOS 15 compatible)

struct WrappingHStack<Item: Hashable, ItemView: View>: View {
    let items: [Item]
    let viewForItem: (Item) -> ItemView
    let spacing: CGFloat

    init(items: [Item], spacing: CGFloat = 8, @ViewBuilder viewForItem: @escaping (Item) -> ItemView) {
        self.items = items
        self.spacing = spacing
        self.viewForItem = viewForItem
    }

    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geometry in
            generateContent(in: geometry)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                viewForItem(item)
                    .padding(.vertical, 2)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > geometry.size.width {
                            width = 0
                            height -= d.height + spacing
                        }
                        let result = width
                        if item == items.last {
                            width = 0
                        } else {
                            width -= d.width + spacing
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == items.last {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geometry -> Color in
            DispatchQueue.main.async {
                binding.wrappedValue = geometry.frame(in: .local).size.height
            }
            return Color.clear
        }
    }
}
