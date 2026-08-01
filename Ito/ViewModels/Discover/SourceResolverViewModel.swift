import Foundation
import SwiftUI
import Combine
import GRDB
import OSLog
import ito_runner

public struct SourceRoute: Equatable {
    public let media: ResolvedPluginMedia
    public let pluginID: String
    public let runner: ItoRunner
    public let anilistID: Int?

    public init(media: ResolvedPluginMedia, pluginID: String, runner: ItoRunner, anilistID: Int?) {
        self.media = media
        self.pluginID = pluginID
        self.runner = runner
        self.anilistID = anilistID
    }

    public static func == (lhs: SourceRoute, rhs: SourceRoute) -> Bool {
        lhs.pluginID == rhs.pluginID
            && lhs.media.key() == rhs.media.key()
            && lhs.anilistID == rhs.anilistID
    }
}

public struct SourceRoutePresentationState: Equatable {
    public enum Phase: Equatable {
        case idle
        case preparing
        case presented
        case dismissing
        case dismissedByUser
    }

    public private(set) var route: SourceRoute?
    public private(set) var isPresented = false
    public private(set) var phase: Phase = .idle
    public private(set) var presentationCount = 0

    public init() {}

    public mutating func present(_ route: SourceRoute) {
        self.route = route
        phase = .preparing
        isPresented = true
        presentationCount += 1
    }

    public mutating func destinationDidAppear() {
        guard isPresented, route != nil else { return }
        phase = .presented
    }

    public mutating func navigationBindingDidSet(_ isActive: Bool) {
        // NavigationLink may transiently write false while reevaluating its
        // hierarchy. Only the explicit Back action starts dismissal.
        guard isActive else { return }
    }

    public mutating func manualDestinationPopRequested() {
        guard isPresented, route != nil else { return }
        phase = .dismissing
        isPresented = false
    }

    public mutating func destinationDidDisappear() {
        guard phase == .dismissing else { return }
        route = nil
        phase = .dismissedByUser
    }
}

public protocol PluginProviding: Sendable {
    var installedPlugins: [String: InstalledPlugin] { get }
    @MainActor func getRunner(for pluginId: String) async throws -> ItoRunner
    func getSearchAdapter(for pluginId: String, mediaType: PluginMediaType) async throws -> any PluginSearching
}

extension PluginManager: @unchecked Sendable, PluginProviding {
    public func getSearchAdapter(for pluginId: String, mediaType: PluginMediaType) async throws -> any PluginSearching {
        let runner = try await getRunner(for: pluginId)
        guard let plugin = installedPlugins[pluginId] else { throw URLError(.badURL) }
        return PluginSearchAdapter(pluginID: plugin.id, pluginVersion: plugin.info.version, mediaType: mediaType, runner: runner)
    }
}

@MainActor
public final class SourceResolverViewModel: ObservableObject {
    public enum State {
        case idle
        case loading(matches: [MatchedSource])
        case completed(matches: [MatchedSource])
        case empty
        case noCompatiblePlugins
        case partialFailure(matches: [MatchedSource], failedPlugins: [String])
        case fatalFailure(error: String)
        case cancelled
        case savedSource(mapping: SourceMappingRecord, payload: ResolvedPluginMedia)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var pluginSearchError: String?
    @Published public private(set) var processingMatchId: String?

    // MARK: - Route Coordinator
    @Published public private(set) var routePresentation = SourceRoutePresentationState()

    public var sourceRoute: SourceRoute? { routePresentation.route }
    public var isSourceDestinationPresented: Bool { routePresentation.isPresented }

    public func present(route: SourceRoute) {
        routePresentation.present(route)
    }

    public func navigationBindingDidSet(_ isActive: Bool) {
        routePresentation.navigationBindingDidSet(isActive)
    }

    public func destinationDidAppear() {
        routePresentation.destinationDidAppear()
    }

    public func manualDestinationPopRequested() {
        routePresentation.manualDestinationPopRequested()
    }

    public func destinationDidDisappear() {
        routePresentation.destinationDidDisappear()
    }

    private let media: DiscoverMedia
    private let repository: SourceMappingRepository
    private let pluginManager: any PluginProviding
    private var resolutionTask: Task<Void, Never>?
    private var mappingCheckTask: Task<Void, Never>?
    private var routePreparationTask: Task<Void, Never>?
    private var hasStartedInitialLookup = false

    var canonicalProvider: String { "anilist" }
    private var canonicalMediaId: String { String(media.id) }
    private var canonicalMediaType: PluginMediaType { media.type == "ANIME" ? .anime : .manga }

    deinit {
        mappingCheckTask?.cancel()
        resolutionTask?.cancel()
        routePreparationTask?.cancel()
    }

    public init(
        media: DiscoverMedia,
        repository: SourceMappingRepository = GRDBSourceMappingRepository(dbWriter: AppDatabase.shared.dbPool),
        pluginManager: any PluginProviding = PluginManager.shared
    ) {
        self.media = media
        self.repository = repository
        self.pluginManager = pluginManager
    }

    private func beginInitialLookup() -> Bool {
        guard !hasStartedInitialLookup else { return false }
        hasStartedInitialLookup = true
        return true
    }

    public func startCheckAndResolve() {
        guard beginInitialLookup() else { return }
        mappingCheckTask?.cancel()
        mappingCheckTask = Task { [weak self] in
            await self?.performCheckAndResolve()
        }
    }

    func checkAndResolve() async {
        guard beginInitialLookup() else { return }
        await performCheckAndResolve()
    }

    private func performCheckAndResolve() async {
        guard !Task.isCancelled else { return }

        guard let (mapping, payload) = await checkExistingMapping() else {
            guard !Task.isCancelled else { return }
            resolve()
            return
        }

        await markMappingUsed(mapping)
        guard !Task.isCancelled else { return }
        setSavedSourceState(mapping: mapping, payload: payload)
    }

    private func prepareRoute(media: ResolvedPluginMedia, pluginID: String) async throws -> SourceRoute {
        let runner = try await pluginManager.getRunner(for: pluginID)
        return SourceRoute(
            media: media,
            pluginID: pluginID,
            runner: runner,
            anilistID: canonicalProvider == "anilist" ? self.media.id : nil
        )
    }

    public func resolve() {
        guard !isSearching else { return }

        resolutionTask?.cancel()

        let request = SourceSearchRequest(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaId,
            mediaType: canonicalMediaType,
            preferredTitle: media.title,
            titleEnglish: media.titleEnglish,
            titleRomaji: media.titleRomaji,
            titleNative: media.titleNative,
            synonyms: media.synonyms
        )

        isSearching = true
        state = .loading(matches: [])

        resolutionTask = Task {
            defer { self.isSearching = false }

            do {
                let matchingPlugins = pluginManager.installedPlugins.values.filter {
                    if request.mediaType == .anime { return $0.info.type == .anime }
                    return $0.info.type == .manga
                }
                guard !matchingPlugins.isEmpty else {
                    if !Task.isCancelled {
                        self.state = .noCompatiblePlugins
                    }
                    return
                }

                var adapters: [any PluginSearching] = []
                for plugin in matchingPlugins {
                    if let adapter = try? await pluginManager.getSearchAdapter(for: plugin.id, mediaType: request.mediaType) {
                        adapters.append(adapter)
                    }
                }

                let rejectedRecords = try await repository.fetchAll(canonicalProvider: request.canonicalProvider, canonicalMediaId: request.canonicalMediaId, mediaType: request.mediaType).filter { $0.decision == .discard }
                var rejectedKeysByPlugin: [String: Set<String>] = [:]
                for record in rejectedRecords {
                    rejectedKeysByPlugin[record.pluginId, default: []].insert(record.pluginMediaKey)
                }

                let resolver = SourceResolver(plugins: adapters)
                let result = await resolver.resolve(
                    request: request,
                    isRejected: { [rejectedKeysByPlugin] pluginId, key in rejectedKeysByPlugin[pluginId]?.contains(key) ?? false }
                ) { [weak self] partialMatches in
                    guard let self = self, self.isSearching else { return }
                    self.state = .loading(matches: partialMatches)
                }

                guard !Task.isCancelled && !result.isCancelled else {
                    self.state = .cancelled
                    return
                }

                if !result.pluginFailures.isEmpty {
                    self.state = .partialFailure(matches: result.matches, failedPlugins: Array(result.pluginFailures.keys))
                } else if result.matches.isEmpty {
                    self.state = .empty
                } else {
                    self.state = .completed(matches: result.matches)
                }

            } catch {
                if Task.isCancelled {
                    self.state = .cancelled
                } else {
                    self.state = .fatalFailure(error: error.localizedDescription)
                }
            }
        }
    }

    public func setSavedSourceState(mapping: SourceMappingRecord, payload: ResolvedPluginMedia) {
        self.state = .savedSource(mapping: mapping, payload: payload)
    }

    public func cancel() {
        resolutionTask?.cancel()
        resolutionTask = nil
        isSearching = false
        state = .cancelled
    }

    public func checkExistingMapping() async -> (SourceMappingRecord, ResolvedPluginMedia)? {
        do {
            let confirmed = try await repository.fetchConfirmed(
                canonicalProvider: canonicalProvider,
                canonicalMediaId: canonicalMediaId,
                mediaType: canonicalMediaType
            )

            for mapping in confirmed {
                guard let payload = mapping.encodedPayload,
                      let version = mapping.payloadVersion,
                      let decoded = try? JSONDecoder().decode(SourceMediaSnapshot.self, from: payload),
                      decoded.version == version else { continue }

                guard let plugin = pluginManager.installedPlugins[mapping.pluginId] else { continue }

                let decodedType: PluginMediaType
                switch decoded.payload {
                case .anime: decodedType = .anime
                case .manga: decodedType = .manga
                }
                guard decodedType == canonicalMediaType else { continue }

                let currentVersion = plugin.info.version
                if let storedVersion = mapping.pluginVersion, currentVersion != storedVersion {
                    continue
                }

                return (mapping, decoded.payload)
            }
        } catch {
            AppLogger.database.error("Failed to check existing mapping: \(error)")
        }
        return nil
    }

    public func markMappingUsed(_ mapping: SourceMappingRecord) async {
        do {
            let updated = SourceMappingRecord(
                canonicalProvider: mapping.canonicalProvider,
                canonicalMediaId: mapping.canonicalMediaId,
                mediaType: mapping.mediaType,
                pluginId: mapping.pluginId,
                pluginMediaKey: mapping.pluginMediaKey,
                decision: mapping.decision,
                matchMethod: mapping.matchMethod,
                confidence: mapping.confidence,
                titleSnapshot: mapping.titleSnapshot,
                createdAt: mapping.createdAt,
                updatedAt: mapping.updatedAt,
                coverURLSnapshot: mapping.coverURLSnapshot,
                encodedPayload: mapping.encodedPayload,
                payloadVersion: mapping.payloadVersion,
                pluginVersion: mapping.pluginVersion,
                lastVerifiedAt: Date()
            )
            try await repository.upsert(updated)
        } catch {
            AppLogger.database.error("Failed to update mapping verification timestamp: \(error)")
        }
    }

    public func confirmAndRoute(match: MatchedSource) {
        guard processingMatchId == nil else { return }
        processingMatchId = match.media.key()
        pluginSearchError = nil

        routePreparationTask?.cancel()
        routePreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.processingMatchId = nil }

            do {
                try await self.confirmAndPrepareRoute(match)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.database.error("Failed to confirm and route: \(error)")
                self.pluginSearchError = "Failed to save or open source: \(error.localizedDescription)"
            }
        }
    }

    func confirmAndPrepareRoute(_ match: MatchedSource) async throws {
        let mapping = try await confirmMatch(match)
        state = .savedSource(mapping: mapping, payload: match.media)
        let route = try await prepareRoute(media: match.media, pluginID: match.pluginID)
        try Task.checkCancellation()
        present(route: route)
    }

    public func openSavedSource(mapping: SourceMappingRecord, payload: ResolvedPluginMedia) {
        guard processingMatchId == nil else { return }
        processingMatchId = payload.key()
        pluginSearchError = nil

        routePreparationTask?.cancel()
        routePreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.processingMatchId = nil }

            do {
                let route = try await self.prepareRoute(media: payload, pluginID: mapping.pluginId)
                try Task.checkCancellation()
                self.present(route: route)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.database.error("Failed to open saved source: \(error)")
                self.pluginSearchError = "Failed to open saved source: \(error.localizedDescription)"
            }
        }
    }

    public func rejectAndMark(match: MatchedSource) {
        guard processingMatchId == nil else { return }
        processingMatchId = match.media.key()
        pluginSearchError = nil

        Task {
            do {
                try await rejectMatch(match)
                await MainActor.run { processingMatchId = nil }
            } catch {
                AppLogger.database.error("Failed to reject match: \(error)")
                await MainActor.run {
                    self.pluginSearchError = "Failed to reject mapping: \(error.localizedDescription)"
                    self.processingMatchId = nil
                }
            }
        }
    }

    @discardableResult
    func confirmMatch(_ match: MatchedSource) async throws -> SourceMappingRecord {
        let snapshot = SourceMediaSnapshot(version: 1, payload: match.media)
        let payload = try JSONEncoder().encode(snapshot)

        let mediaKey: String
        let title: String
        let coverUrl: String?
        switch match.media {
        case .manga(let m):
            mediaKey = m.key
            title = m.title
            coverUrl = m.cover
        case .anime(let a):
            mediaKey = a.key
            title = a.title
            coverUrl = a.cover
        }

        let now = Date()
        let record = SourceMappingRecord(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaId,
            mediaType: canonicalMediaType,
            pluginId: match.pluginID,
            pluginMediaKey: mediaKey,
            decision: .autoConfirm,
            matchMethod: match.matchMethod,
            confidence: match.score,
            titleSnapshot: title,
            createdAt: now,
            updatedAt: now,
            coverURLSnapshot: coverUrl,
            encodedPayload: payload,
            payloadVersion: 1,
            pluginVersion: match.pluginVersion,
            lastVerifiedAt: now
        )

        try await repository.upsert(record)
        return record
    }

    func rejectMatch(_ match: MatchedSource) async throws {
        // Remove from current state to prevent full search restart
        if case .completed(let matches) = state {
            let updated = matches.map { $0 == match ? MatchedSource(pluginID: $0.pluginID, pluginVersion: $0.pluginVersion, media: $0.media, matchMethod: $0.matchMethod, score: $0.score, decision: .discard) : $0 }
            self.state = .completed(matches: updated)
        }

        let mediaKey: String
        switch match.media {
        case .manga(let m): mediaKey = m.key
        case .anime(let a): mediaKey = a.key
        }

        try await repository.persistRejection(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaId,
            mediaType: canonicalMediaType,
            pluginId: match.pluginID,
            pluginMediaKey: mediaKey
        )
    }
}

public extension ResolvedPluginMedia {
    func key() -> String {
        switch self {
        case .manga(let m): return m.key
        case .anime(let a): return a.key
        }
    }
}
