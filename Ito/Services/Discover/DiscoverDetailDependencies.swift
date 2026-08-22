import Combine
import Foundation
import UIKit
import ito_runner

@MainActor
protocol DiscoverDetailServing: AnyObject {
    func fetchDiscoverDetails(id: Int) async throws -> DiscoverMedia?
}

extension DiscoverManager: DiscoverDetailServing {
    func fetchDiscoverDetails(id: Int) async throws -> DiscoverMedia? {
        try await fetchMediaDetails(id: id)
    }
}

@MainActor
protocol DiscoverDetailThemeServing: AnyObject {
    func cachedTheme(for mediaKey: String) async -> ThemeColors?
    func extractTheme(from image: UIImage, for mediaKey: String) async -> ThemeColors?
}

extension ThemeManager: DiscoverDetailThemeServing {
    func cachedTheme(for mediaKey: String) async -> ThemeColors? {
        await getTheme(for: mediaKey)
    }

    func extractTheme(from image: UIImage, for mediaKey: String) async -> ThemeColors? {
        await extractAndCache(image: image, for: mediaKey)
        return await getTheme(for: mediaKey)
    }
}

enum DiscoverDetailMessage: Equatable {
    case refreshFailed
}

@MainActor
protocol DiscoverDetailMessagePresenting: AnyObject {
    func present(_ message: DiscoverDetailMessage)
}

@MainActor
final class AppMessageDiscoverDetailPresenter: DiscoverDetailMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: DiscoverDetailMessage) {
        switch message {
        case .refreshFailed:
            messageCenter.publish(.discoverDetailRefreshFailed)
        }
    }
}

@MainActor
protocol SourceResolverPluginProviding: SourceRunnerProviding {
    var installedPlugins: [String: InstalledPlugin] { get }
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> { get }

    func sourceSearchAdapter(
        for pluginID: String,
        mediaType: PluginMediaType
    ) async throws -> any PluginSearching
}

extension SourceResolverPluginProviding {
    func sourceSearchAdapter(
        for pluginID: String,
        mediaType: PluginMediaType
    ) async throws -> any PluginSearching {
        let context = try await sourceRunnerContext(for: pluginID)
        guard let plugin = installedPlugins[pluginID] else {
            throw URLError(.fileDoesNotExist)
        }
        return PluginSearchAdapter(
            pluginID: plugin.id,
            pluginVersion: plugin.info.version,
            mediaType: mediaType,
            runner: context.runner
        )
    }
}

extension PluginManager: SourceResolverPluginProviding {}

@MainActor
struct PreparedDiscoverDetailDependencies {
    let sourceMappingRepository: any SourceMappingRepository
    let pluginProvider: any SourceResolverPluginProviding
    let detailService: any DiscoverDetailServing
    let themeService: any DiscoverDetailThemeServing
    let sourceRouteFactory: any SourceRouteBuilding

    static func unavailable() -> Self {
        let dependency = UnavailableDiscoverDetailDependency()
        return Self(
            sourceMappingRepository: dependency,
            pluginProvider: dependency,
            detailService: dependency,
            themeService: dependency,
            sourceRouteFactory: SourceRouteFactory()
        )
    }
}

private enum DiscoverDetailDependencyUnavailableError: Error {
    case unavailable
}

@MainActor
private final class UnavailableDiscoverDetailDependency: DiscoverDetailServing,
    DiscoverDetailThemeServing, SourceResolverPluginProviding, SourceMappingRepository,
    @unchecked Sendable {
    let installedPlugins: [String: InstalledPlugin] = [:]

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func fetchDiscoverDetails(id: Int) async throws -> DiscoverMedia? {
        _ = id
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func cachedTheme(for mediaKey: String) async -> ThemeColors? {
        _ = mediaKey
        return nil
    }

    func extractTheme(from image: UIImage, for mediaKey: String) async -> ThemeColors? {
        _ = image
        _ = mediaKey
        return nil
    }

    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        _ = pluginID
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func evictSourceRunner(for pluginID: String) {
        _ = pluginID
    }

    func sourceSearchAdapter(
        for pluginID: String,
        mediaType: PluginMediaType
    ) async throws -> any PluginSearching {
        _ = pluginID
        _ = mediaType
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func fetchConfirmed(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType
    ) async throws -> [SourceMappingRecord] {
        _ = canonicalProvider
        _ = canonicalMediaId
        _ = mediaType
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func fetchAll(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType
    ) async throws -> [SourceMappingRecord] {
        _ = canonicalProvider
        _ = canonicalMediaId
        _ = mediaType
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func find(pluginId: String, pluginMediaKey: String) async throws -> [SourceMappingRecord] {
        _ = pluginId
        _ = pluginMediaKey
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func upsert(_ record: SourceMappingRecord) async throws {
        _ = record
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func persistRejection(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        _ = canonicalProvider
        _ = canonicalMediaId
        _ = mediaType
        _ = pluginId
        _ = pluginMediaKey
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }

    func unlink(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        _ = canonicalProvider
        _ = canonicalMediaId
        _ = mediaType
        _ = pluginId
        _ = pluginMediaKey
        throw DiscoverDetailDependencyUnavailableError.unavailable
    }
}
