import UIKit
import CoreGraphics
import SwiftUI

public struct ThemeColors: Equatable, Sendable, Codable {
    public let dominantHex: String
    public let secondaryHex: String

    nonisolated public init(dominantHex: String, secondaryHex: String) {
        self.dominantHex = dominantHex
        self.secondaryHex = secondaryHex
    }
}

public final class ColorExtractor: Sendable {
    public static let shared = ColorExtractor()
    private init() {}

    public func extractColors(from image: UIImage) async -> ThemeColors? {
        guard let cgImage = image.cgImage else { return nil }

        return await Task.detached(priority: .userInitiated) {
            let width = 40
            let height = 40
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var rawData = [UInt8](repeating: 0, count: width * height * 4)

            guard let context = CGContext(
                data: &rawData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return nil
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            struct ColorVec: Equatable {
                var r: Float, g: Float, b: Float
                func distanceSq(to other: ColorVec) -> Float {
                    let dr = r - other.r, dg = g - other.g, db = b - other.b
                    return dr * dr + dg * dg + db * db
                }
            }

            var pixels: [ColorVec] = []
            pixels.reserveCapacity(width * height)
            for i in stride(from: 0, to: rawData.count, by: 4) {
                let a = rawData[i + 3]
                if a > 127 { // Only somewhat opaque pixels
                    pixels.append(ColorVec(r: Float(rawData[i]), g: Float(rawData[i + 1]), b: Float(rawData[i + 2])))
                }
            }

            guard !pixels.isEmpty else { return nil }

            // K-Means with K=4
            let k = min(4, pixels.count)
            var centroids = (0..<k).map { i -> ColorVec in
                pixels[(i * pixels.count) / k] // rough scatter initialization
            }

            var clusters: [[ColorVec]] = Array(repeating: [], count: k)

            for _ in 0..<10 {
                clusters = Array(repeating: [], count: k)
                for p in pixels {
                    var minDist = Float.infinity
                    var bestIdx = 0
                    for i in 0..<k {
                        let d = p.distanceSq(to: centroids[i])
                        if d < minDist {
                            minDist = d
                            bestIdx = i
                        }
                    }
                    clusters[bestIdx].append(p)
                }

                var changed = false
                for i in 0..<k {
                    let cluster = clusters[i]
                    if cluster.isEmpty { continue }
                    var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0
                    for c in cluster { sumR += c.r; sumG += c.g; sumB += c.b }
                    let count = Float(cluster.count)
                    let newC = ColorVec(r: sumR / count, g: sumG / count, b: sumB / count)
                    if newC.distanceSq(to: centroids[i]) > 1.0 { changed = true }
                    centroids[i] = newC
                }
                if !changed { break }
            }

            // Sort by size to find dominant
            let sortedIdx = (0..<k).sorted { clusters[$0].count > clusters[$1].count }
            let dom = centroids[sortedIdx[0]]

            // Try to find a secondary color that is somewhat different
            var sec = dom
            if sortedIdx.count > 1 {
                for i in 1..<sortedIdx.count {
                    let c = centroids[sortedIdx[i]]
                    if c.distanceSq(to: dom) > 2000 { // Ensuring accent has *some* contrast
                        sec = c
                        break
                    }
                }
                if sec == dom && sortedIdx.count > 1 {
                    sec = centroids[sortedIdx[1]]
                }
            }

            return ThemeColors(
                dominantHex: String(format: "#%02lX%02lX%02lX", Int(dom.r), Int(dom.g), Int(dom.b)),
                secondaryHex: String(format: "#%02lX%02lX%02lX", Int(sec.r), Int(sec.g), Int(sec.b))
            )
        }.value
    }
}

public extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
