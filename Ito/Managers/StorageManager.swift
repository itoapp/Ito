import Foundation
import Combine
import Nuke

public class StorageManager: ObservableObject {
    public static let shared = StorageManager()

    private let cacheLimitKey = "Ito.DiskCacheLimitGB"
    private let defaultLimitGB: Double = 10.0

    @Published public var diskCacheLimitGB: Double {
        didSet {
            UserDefaults.standard.set(diskCacheLimitGB, forKey: cacheLimitKey)
            updateCacheLimit()
        }
    }

    @Published public private(set) var currentCacheSizeBytes: Int = 0

    // Maintain a reference to our custom data cache
    private var dataCache: DataCache?

    private init() {
        if UserDefaults.standard.object(forKey: cacheLimitKey) != nil {
            self.diskCacheLimitGB = UserDefaults.standard.double(forKey: cacheLimitKey)
        } else {
            self.diskCacheLimitGB = defaultLimitGB
        }

        setupNukePipeline()
        refreshCacheSize()
    }

    private func setupNukePipeline() {
        let capacityBytes = Int(diskCacheLimitGB * 1024 * 1024 * 1024)

        do {
            let dataCache = try DataCache(name: "com.ito.datacache")
            dataCache.sizeLimit = capacityBytes
            self.dataCache = dataCache

            // Set up Nuke to use our aggressive data cache instead of URLCache
            ImagePipeline.shared = ImagePipeline {
                $0.dataCache = dataCache
                let config = URLSessionConfiguration.default
                config.urlCache = nil
                config.httpAdditionalHeaders = ["User-Agent": CloudflareManager.defaultUserAgent]
                $0.dataLoader = DataLoader(configuration: config)
            }
        } catch {
            print("Failed to initialize Nuke DataCache: \(error)")
            // Fallback to default aggressive cache if custom instantiation fails
            ImagePipeline.shared = ImagePipeline(configuration: .withDataCache)
        }
    }

    private func updateCacheLimit() {
        let capacityBytes = Int(diskCacheLimitGB * 1024 * 1024 * 1024)
        dataCache?.sizeLimit = capacityBytes
    }

    public func refreshCacheSize() {
        if let dataCache = dataCache {
            self.currentCacheSizeBytes = dataCache.totalSize
        }
    }

    public func clearCache() {
        // Clear memory cache
        ImageCache.shared.removeAll()
        // Clear disk cache
        dataCache?.removeAll()

        // Also clear URLCache just in case anything else used it
        URLCache.shared.removeAllCachedResponses()

        refreshCacheSize()
    }

    public func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
