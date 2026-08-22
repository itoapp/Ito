import Combine
import Foundation
import UIKit

@MainActor
final class DiscoverDetailViewModel: ObservableObject {
    enum DetailLoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published private(set) var media: DiscoverMedia
    @Published private(set) var detailLoadState: DetailLoadState = .idle
    @Published private(set) var theme: ThemeColors?
    @Published private(set) var installedPlugins: [String: InstalledPlugin]
    @Published private(set) var confirmationCandidate: MatchedSource?
    @Published private(set) var rejectionCandidate: MatchedSource?

    let sourceResolver: SourceResolverViewModel

    private let detailService: any DiscoverDetailServing
    private let themeService: any DiscoverDetailThemeServing
    private let messagePresenter: any DiscoverDetailMessagePresenting
    private let mediaID: Int

    private var detailTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var detailOperationID: UUID?
    private var themeOperationID: UUID?
    private var hasStarted = false
    private var cancellables = Set<AnyCancellable>()

    init(
        media: DiscoverMedia,
        detailService: any DiscoverDetailServing,
        themeService: any DiscoverDetailThemeServing,
        messagePresenter: any DiscoverDetailMessagePresenting,
        pluginProvider: any SourceResolverPluginProviding,
        sourceResolver: SourceResolverViewModel
    ) {
        self.media = media
        self.detailService = detailService
        self.themeService = themeService
        self.messagePresenter = messagePresenter
        self.sourceResolver = sourceResolver
        self.mediaID = media.id
        self.installedPlugins = pluginProvider.installedPlugins

        pluginProvider.installedPluginsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] plugins in
                self?.installedPlugins = plugins
            }
            .store(in: &cancellables)

        sourceResolver.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    deinit {
        detailOperationID = nil
        themeOperationID = nil
        detailTask?.cancel()
        themeTask?.cancel()
    }

    var mediaThemeKey: String {
        "anilist_\(mediaID)"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        loadCachedTheme()
        refreshDetails()
        sourceResolver.startCheckAndResolve()
    }

    func retryDetails() {
        refreshDetails()
    }

    func heroImageLoaded(_ image: UIImage) {
        themeTask?.cancel()
        let operationID = UUID()
        themeOperationID = operationID
        let themeKey = mediaThemeKey
        let themeService = themeService
        themeTask = Task { [weak self, themeService] in
            let extractedTheme = await themeService.extractTheme(from: image, for: themeKey)
            self?.publishTheme(
                extractedTheme,
                operationID: operationID,
                themeKey: themeKey
            )
        }
    }

    func requestConfirmation(for match: MatchedSource) {
        confirmationCandidate = match
    }

    func cancelConfirmation() {
        confirmationCandidate = nil
    }

    func confirmPresentedSource(_ match: MatchedSource) {
        guard confirmationCandidate == match else { return }
        confirmationCandidate = nil
        sourceResolver.confirmAndRoute(match: match)
    }

    func confirmSourceDirectly(_ match: MatchedSource) {
        sourceResolver.confirmAndRoute(match: match)
    }

    func requestRejection(for match: MatchedSource) {
        rejectionCandidate = match
    }

    func cancelRejection() {
        rejectionCandidate = nil
    }

    func rejectPresentedSource(_ match: MatchedSource) {
        guard rejectionCandidate == match else { return }
        rejectionCandidate = nil
        sourceResolver.rejectAndMark(match: match)
    }

    func cancelScreenOperations() {
        detailOperationID = nil
        themeOperationID = nil
        detailTask?.cancel()
        themeTask?.cancel()
        detailTask = nil
        themeTask = nil
        if detailLoadState == .loading {
            detailLoadState = .idle
        }
        sourceResolver.cancelOwnedOperations()
    }

    private func refreshDetails() {
        detailTask?.cancel()
        let operationID = UUID()
        detailOperationID = operationID
        detailLoadState = .loading
        let requestedMediaID = mediaID
        let detailService = detailService

        detailTask = Task { [weak self, detailService] in
            do {
                let fetchedMedia = try await detailService.fetchDiscoverDetails(
                    id: requestedMediaID
                )
                self?.publishDetailSuccess(
                    fetchedMedia,
                    operationID: operationID,
                    mediaID: requestedMediaID
                )
            } catch is CancellationError {
                self?.publishDetailCancellation(operationID: operationID)
            } catch {
                self?.publishDetailFailure(
                    operationID: operationID,
                    mediaID: requestedMediaID
                )
            }
        }
    }

    private func loadCachedTheme() {
        themeTask?.cancel()
        let operationID = UUID()
        themeOperationID = operationID
        let themeKey = mediaThemeKey
        let themeService = themeService

        themeTask = Task { [weak self, themeService] in
            let cachedTheme = await themeService.cachedTheme(for: themeKey)
            self?.publishTheme(
                cachedTheme,
                operationID: operationID,
                themeKey: themeKey
            )
        }
    }

    private func publishDetailSuccess(
        _ fetchedMedia: DiscoverMedia?,
        operationID: UUID,
        mediaID: Int
    ) {
        guard isCurrentDetailOperation(operationID, mediaID: mediaID) else { return }
        if let fetchedMedia, fetchedMedia.id == mediaID {
            media = fetchedMedia
        }
        detailOperationID = nil
        detailTask = nil
        detailLoadState = .loaded
    }

    private func publishDetailCancellation(operationID: UUID) {
        guard detailOperationID == operationID else { return }
        detailOperationID = nil
        detailTask = nil
        detailLoadState = .idle
    }

    private func publishDetailFailure(operationID: UUID, mediaID: Int) {
        guard isCurrentDetailOperation(operationID, mediaID: mediaID) else { return }
        detailOperationID = nil
        detailTask = nil
        detailLoadState = .failed
        messagePresenter.present(.refreshFailed)
    }

    private func publishTheme(
        _ publishedTheme: ThemeColors?,
        operationID: UUID,
        themeKey: String
    ) {
        guard isCurrentThemeOperation(operationID, themeKey: themeKey) else { return }
        if let publishedTheme {
            theme = publishedTheme
        }
        themeOperationID = nil
        themeTask = nil
    }

    private func isCurrentDetailOperation(_ operationID: UUID, mediaID: Int) -> Bool {
        detailOperationID == operationID
            && self.mediaID == mediaID
            && !Task.isCancelled
    }

    private func isCurrentThemeOperation(_ operationID: UUID, themeKey: String) -> Bool {
        themeOperationID == operationID
            && mediaThemeKey == themeKey
            && !Task.isCancelled
    }
}
