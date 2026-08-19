import CryptoKit
import Foundation
import QuickLookThumbnailing
import UIKit

actor MarketAssetLogoDiskCache {
    static let shared = MarketAssetLogoDiskCache()

    private let fileManager = FileManager.default
    private var completedRenderWrites = 0

    private var rootDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AssetTimeMachine", isDirectory: true)
            .appendingPathComponent("market-logos-v1", isDirectory: true)
    }

    func renderedData(for remoteURL: URL) -> Data? {
        guard let renderedURL = renderedFileURL(for: remoteURL) else { return nil }
        return try? Data(contentsOf: renderedURL)
    }

    func sourceFile(for remoteURL: URL) async -> URL? {
        guard let sourceURL = sourceFileURL(for: remoteURL) else { return nil }
        if fileManager.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  !data.isEmpty else {
                return nil
            }
            try prepareDirectory(for: sourceURL)
            try data.write(to: sourceURL, options: .atomic)
            return sourceURL
        } catch {
            return nil
        }
    }

    func saveRenderedData(_ data: Data, for remoteURL: URL) {
        guard !data.isEmpty, let renderedURL = renderedFileURL(for: remoteURL) else { return }
        do {
            try prepareDirectory(for: renderedURL)
            try data.write(to: renderedURL, options: .atomic)
            completedRenderWrites &+= 1
            if completedRenderWrites.isMultiple(of: 100) {
                pruneIfNeeded()
            }
        } catch {
            // Logo caching is a visual optimization and must never block the app.
        }
    }

    private func sourceFileURL(for remoteURL: URL) -> URL? {
        guard let rootDirectory else { return nil }
        let fileExtension = remoteURL.pathExtension.isEmpty ? "asset" : remoteURL.pathExtension.lowercased()
        return rootDirectory.appendingPathComponent("\(cacheKey(for: remoteURL)).\(fileExtension)")
    }

    private func renderedFileURL(for remoteURL: URL) -> URL? {
        rootDirectory?.appendingPathComponent("\(cacheKey(for: remoteURL)).png")
    }

    private func cacheKey(for remoteURL: URL) -> String {
        SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func prepareDirectory(for fileURL: URL) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func pruneIfNeeded() {
        guard let rootDirectory,
              let files = try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ),
              files.count > 1_600 else { return }

        let sortedFiles = files.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return leftDate < rightDate
        }
        for fileURL in sortedFiles.prefix(files.count - 1_200) {
            try? fileManager.removeItem(at: fileURL)
        }
    }
}

@MainActor
enum MarketAssetLogoImageLoader {
    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    private static var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    static func image(for remoteURL: URL, pointSize: CGFloat) async -> UIImage? {
        let key = remoteURL.absoluteString as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        if let task = inFlightTasks[remoteURL.absoluteString] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            await loadImage(for: remoteURL, pointSize: pointSize)
        }
        inFlightTasks[remoteURL.absoluteString] = task
        let image = await task.value
        inFlightTasks[remoteURL.absoluteString] = nil
        if let image {
            let pixelCost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            memoryCache.setObject(image, forKey: key, cost: pixelCost)
        }
        return image
    }

    private static func loadImage(for remoteURL: URL, pointSize: CGFloat) async -> UIImage? {
        if let renderedData = await MarketAssetLogoDiskCache.shared.renderedData(for: remoteURL),
           let image = UIImage(data: renderedData) {
            return image
        }

        guard let sourceURL = await MarketAssetLogoDiskCache.shared.sourceFile(for: remoteURL) else {
            return nil
        }
        if let data = try? Data(contentsOf: sourceURL),
           let image = UIImage(data: data) {
            if let pngData = image.pngData() {
                await MarketAssetLogoDiskCache.shared.saveRenderedData(pngData, for: remoteURL)
            }
            return image
        }

        let scale = UIScreen.main.scale
        let request = QLThumbnailGenerator.Request(
            fileAt: sourceURL,
            size: CGSize(width: max(40, pointSize), height: max(40, pointSize)),
            scale: scale,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.uiImage
        if let pngData = image.pngData() {
            await MarketAssetLogoDiskCache.shared.saveRenderedData(pngData, for: remoteURL)
        }
        return image
    }
}
