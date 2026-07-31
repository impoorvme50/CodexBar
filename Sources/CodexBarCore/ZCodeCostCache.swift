import Foundation

/// On-disk cache for the ZCode/WorkBuddy cost scanner. Mirrors the PiSessionCostCache
/// shape: per-provider day→model→packed-usage buckets plus per-file mtime/size/parsedBytes
/// for incremental rescans. Pricing invalidation flows through `pricingKey`.
enum ZCodeCostCacheIO {
    private static let artifactVersion = 1

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("zcode-sessions-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil) -> ZCodeCostCache {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ZCodeCostCache.self, from: data),
              decoded.version == Self.artifactVersion
        else {
            return ZCodeCostCache(version: Self.artifactVersion)
        }
        return decoded
    }

    static func save(
        cache: ZCodeCostCache,
        cacheRoot: URL? = nil,
        calendar: Calendar = .current)
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

struct ZCodeCostCache: Codable {
    var version: Int
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var pricingKey: String?
    /// provider rawValue → dayKey ("YYYY-MM-DD") → modelName → packed usage
    var daysByProvider: [String: [String: [String: PiPackedUsage]]] = [:]
    /// per-file incremental state, keyed by absolute file path
    var files: [String: ZCodeFileUsage] = [:]

    init(version: Int = 1) {
        self.version = version
    }
}

struct ZCodeFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64
    /// provider rawValue → dayKey → modelName → packed usage (this file's contributions)
    var contributions: [String: [String: [String: PiPackedUsage]]]

    init(
        mtimeUnixMs: Int64,
        size: Int64,
        parsedBytes: Int64,
        contributions: [String: [String: [String: PiPackedUsage]]] = [:])
    {
        self.mtimeUnixMs = mtimeUnixMs
        self.size = size
        self.parsedBytes = parsedBytes
        self.contributions = contributions
    }
}
