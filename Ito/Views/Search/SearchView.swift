import SwiftUI
import ito_runner

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                // Scope picker — iOS 15.4 compatible segmented control
                Picker("Scope", selection: $viewModel.searchScope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !viewModel.recentSearches.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Recent Searches")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                Spacer()
                                Button("Clear") {
                                    viewModel.clearRecentSearches()
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 12)

                            ForEach(viewModel.recentSearches, id: \.self) { recent in
                                Button {
                                    viewModel.searchText = recent
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                        Text(recent)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.up.left")
                                            .foregroundStyle(.tertiary)
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider()
                                    .padding(.leading, 46)
                            }
                        }
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                                .padding(.top, 100)

                            Text("Explore")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text("Find Manga, Anime, and Novels across all your plugins.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                } else if viewModel.isSearching && viewModel.searchResults.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Searching plugins...")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 100)
                } else {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(viewModel.searchResults.keys.sorted(), id: \.self) { pluginName in
                            if let results = viewModel.searchResults[pluginName], !results.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    sectionHeader(pluginName: pluginName)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(results) { result in
                                                NavigationLink(destination: result.destination) {
                                                    SearchCardView(result: result)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                    if viewModel.isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading more sources...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    } else if viewModel.searchResults.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No results found.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 50)
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Manga, Anime, and Novels")
            .disableAutocorrection(true)
        }
        .navigationViewStyle(.stack)
    }

    private func sectionHeader(pluginName: String) -> some View {
        HStack {
            Text(pluginName)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Spacer()

            if viewModel.isSearching {
                let stillSearching = viewModel.activeTasks.contains { id in
                    PluginManager.shared.installedPlugins[id]?.info.name == pluginName
                }
                if stillSearching {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView()
    }
}
