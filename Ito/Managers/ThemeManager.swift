import SwiftUI
import GRDB
import Combine

@MainActor
public class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    // In-memory cache for fast lookups (prevent DB hit every pop/push)
    @Published public var memoryCache: [String: ThemeColors] = [:]

    private init() {}

    public func getTheme(for mediaKey: String) async -> ThemeColors? {
        if let mem = memoryCache[mediaKey] { return mem }

        do {
            let record = try await AppDatabase.shared.dbPool.read { db in
                try ThemeCacheRecord.fetchOne(db, key: mediaKey)
            }
            if let rec = record {
                let colors = ThemeColors(dominantHex: rec.dominantHex, secondaryHex: rec.secondaryHex)
                self.memoryCache[mediaKey] = colors
                return colors
            }
        } catch {
            print("Failed to read theme cache: \(error)")
        }
        return nil
    }

    public func extractAndCache(image: UIImage, for mediaKey: String) async {
        guard memoryCache[mediaKey] == nil else { return } // already cached

        if let colors = await ColorExtractor.shared.extractColors(from: image) {
            self.memoryCache[mediaKey] = colors

            // Persist to DB
            Task {
                do {
                    try await AppDatabase.shared.dbPool.write { db in
                    let record = ThemeCacheRecord(mediaKey: mediaKey, dominantHex: colors.dominantHex, secondaryHex: colors.secondaryHex)
                        try record.save(db)
                    }
                } catch {
                    print("Failed to save theme cache: \(error)")
                }
            }
        }
    }
}
