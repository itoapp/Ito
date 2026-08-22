import SwiftUI
import ito_runner

struct ListingView: View {
    @StateObject private var viewModel: ListingViewModel
    private let routeFactory: SearchRouteFactory

    init(viewModel: ListingViewModel, routeFactory: SearchRouteFactory) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.routeFactory = routeFactory
    }

    var body: some View {
        listingContent
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.loadInitialIfNeeded()
            }
            .onDisappear {
                viewModel.cancel()
            }
    }

    @ViewBuilder
    private var listingContent: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ProgressView("Loading \(viewModel.title)...")
        case .failure(let error):
            failureView(message: error)
        case .cancelled:
            failureView(message: "Loading was cancelled.")
        case .empty:
            VStack(spacing: 12) {
                Text("No results found.")
                    .foregroundStyle(.secondary)
                if viewModel.hasNextPage, viewModel.paginationState == .idle {
                    Button("Load Next Page") {
                        Task { await viewModel.loadMore() }
                    }
                    .buttonStyle(.bordered)
                }
                paginationFooter
            }
        case .content:
            resultsList
        }
    }

    private var resultsList: some View {
        List {
            switch viewModel.pluginType {
            case .anime:
                ForEach(viewModel.animes, id: \.key) { anime in
                    MediaRowView(media: anime) {
                        routeFactory.destination(for: viewModel.destination(for: anime))
                    }
                    .onAppear { loadMoreIfNeeded(lastKey: viewModel.animes.last?.key, key: anime.key) }
                }
            case .manga:
                ForEach(viewModel.mangas, id: \.key) { manga in
                    MediaRowView(media: manga) {
                        routeFactory.destination(for: viewModel.destination(for: manga))
                    }
                    .onAppear { loadMoreIfNeeded(lastKey: viewModel.mangas.last?.key, key: manga.key) }
                }
            case .novel:
                ForEach(viewModel.novels, id: \.key) { novel in
                    MediaRowView(media: novel) {
                        routeFactory.destination(for: viewModel.destination(for: novel))
                    }
                    .onAppear { loadMoreIfNeeded(lastKey: viewModel.novels.last?.key, key: novel.key) }
                }
            @unknown default:
                EmptyView()
            }

            paginationFooter
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var paginationFooter: some View {
        switch viewModel.paginationState {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding()
        case .failure(_, let reason):
            VStack(spacing: 8) {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.red)
                Button("Retry") {
                    Task { await viewModel.retry() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding()
        case .continuationRequired:
            Button("Load Next Page") {
                Task { await viewModel.loadMore() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .padding()
        case .idle, .exhausted:
            EmptyView()
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).foregroundColor(.red)
            Button("Retry") {
                Task { await viewModel.retry() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func loadMoreIfNeeded(lastKey: String?, key: String) {
        guard key == lastKey else { return }
        Task { await viewModel.loadMore() }
    }
}
