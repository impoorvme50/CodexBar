import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cost/token scanner for the `.zai` provider. Reads two local log sources that both serve
/// GLM coding-plan traffic:
///
/// 1. **zcode CLI rollout** — `~/.zcode/cli/rollout/*.jsonl`. Each line is one LLM call with a
///    `usage:{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens}` block, a
///    `model:{modelId:"GLM-5.2"}` block, and a `startedAt` timestamp.
/// 2. **workbuddy traces** — `~/.workbuddy/traces/**/*.json`. Each file is one trace with an
///    aggregated `trace.modelInfo:{totalInputTokens,totalOutputTokens,totalCachedTokens}` and
///    `trace.startedAt`.
///
/// Mirrors `PiSessionCostScanner`'s shape (Options, `loadDailyReportCancellable`,
/// `loadCachedDailyReportResult`, buildReport) but is gated on `.zai` only.
enum ZCodeCostScanner {
    private static let costScale: Double = 1_000_000_000.0
    private static let costFormulaVersion = 1

    struct Options {
        var zcodeRolloutRoot: URL?
        var workbuddyTracesRoot: URL?
        var cacheRoot: URL?
        var calendar: Calendar
        var refreshMinIntervalSeconds: TimeInterval = 60
        var forceRescan: Bool = false

        init(
            zcodeRolloutRoot: URL? = nil,
            workbuddyTracesRoot: URL? = nil,
            cacheRoot: URL? = nil,
            calendar: Calendar = .current,
            refreshMinIntervalSeconds: TimeInterval = 60,
            forceRescan: Bool = false)
        {
            self.zcodeRolloutRoot = zcodeRolloutRoot
            self.workbuddyTracesRoot = workbuddyTracesRoot
            self.cacheRoot = cacheRoot
            self.calendar = calendar
            self.refreshMinIntervalSeconds = refreshMinIntervalSeconds
            self.forceRescan = forceRescan
        }
    }

    struct CachedDailyReportResult {
        let report: CostUsageDailyReport
        let lastScanAt: Date?
    }

    // MARK: - Entry points

    static func loadDailyReportCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> CostUsageDailyReport
    {
        guard provider == .zai else {
            return CostUsageDailyReport(data: [], summary: nil)
        }

        let cacheRoot = options.cacheRoot
        var cache = ZCodeCostCacheIO.load(cacheRoot: cacheRoot)
        let pricingKey = self.pricingKey()
        let forceRescan = options.forceRescan || cache.pricingKey != pricingKey

        if !forceRescan, !cache.daysByProvider.isEmpty {
            let lastScanMs = cache.lastScanUnixMs
            let elapsed = now.timeIntervalSince1970 - Double(lastScanMs) / 1000.0
            if elapsed < options.refreshMinIntervalSeconds {
                return self.buildReport(
                    provider: provider,
                    cache: cache,
                    since: since,
                    until: until,
                    calendar: options.calendar)
            }
        }

        let roots = self.sessionRoots(options: options)
        for root in roots {
            try self.scanDirectory(
                root: root,
                cache: &cache,
                provider: provider,
                forceRescan: forceRescan,
                checkCancellation: checkCancellation)
        }

        cache.pricingKey = pricingKey
        cache.lastScanUnixMs = Int64(now.timeIntervalSince1970 * 1000)
        cache.scanSinceKey = self.dayKey(from: since, calendar: options.calendar)
        cache.scanUntilKey = self.dayKey(from: until, calendar: options.calendar)
        ZCodeCostCacheIO.save(cache: cache, cacheRoot: cacheRoot, calendar: options.calendar)

        return self.buildReport(
            provider: provider,
            cache: cache,
            since: since,
            until: until,
            calendar: options.calendar)
    }

    static func loadCachedDailyReportResult(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        cacheRoot: URL?,
        calendar: Calendar = .current) -> CachedDailyReportResult?
    {
        guard provider == .zai else { return nil }
        let cache = ZCodeCostCacheIO.load(cacheRoot: cacheRoot)
        guard !cache.daysByProvider.isEmpty else { return nil }
        let report = self.buildReport(
            provider: provider,
            cache: cache,
            since: since,
            until: until,
            calendar: calendar)
        let lastScanAt = cache.lastScanUnixMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000.0)
            : nil
        return CachedDailyReportResult(report: report, lastScanAt: lastScanAt)
    }

    // MARK: - Directory scanning

    private static func sessionRoots(options: Options) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let zcodeRoot = options.zcodeRolloutRoot
            ?? home.appendingPathComponent(".zcode/cli/rollout", isDirectory: true)
        let workbuddyRoot = options.workbuddyTracesRoot
            ?? home.appendingPathComponent(".workbuddy/traces", isDirectory: true)
        return [zcodeRoot, workbuddyRoot]
    }

    private static func scanDirectory(
        root: URL,
        cache: inout ZCodeCostCache,
        provider: UsageProvider,
        forceRescan: Bool,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws
    {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }

        for case let fileURL as URL in enumerator {
            if let checkCancellation { try checkCancellation() }
            let pathExtension = fileURL.pathExtension.lowercased()
            guard pathExtension == "jsonl" || pathExtension == "json" else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? Date.distantPast
            let size = values?.fileSize ?? 0
            let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000.0)
            let pathKey = fileURL.path

            if !forceRescan,
               let cached = cache.files[pathKey],
               cached.mtimeUnixMs == mtimeMs, cached.size == Int64(size)
            {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL) else { continue }

            var fileContributions: [String: [String: [String: PiPackedUsage]]] = [:]
            if pathExtension == "jsonl" {
                self.parseJSONL(
                    data: data,
                    provider: provider,
                    calendar: cache.timeZoneIdentifier.map { _ in Calendar(identifier: .gregorian) } ?? .current,
                    into: &fileContributions)
            } else {
                self.parseWorkBuddyTrace(
                    data: data,
                    provider: provider,
                    calendar: .current,
                    into: &fileContributions)
            }

            // Subtract old contributions for this file (if rescanning), then add new.
            if let oldContribs = cache.files[pathKey]?.contributions {
                self.mergeContributions(into: &cache.daysByProvider, from: oldContribs, sign: -1)
            }
            self.mergeContributions(into: &cache.daysByProvider, from: fileContributions, sign: 1)

            cache.files[pathKey] = ZCodeFileUsage(
                mtimeUnixMs: mtimeMs,
                size: Int64(size),
                parsedBytes: Int64(data.count),
                contributions: fileContributions)
        }
    }

    // MARK: - zcode JSONL parsing

    /// Parses a zcode rollout JSONL file line by line. Each line is one LLM call with a
    /// `usage` block, `model.modelId`, and `startedAt` timestamp.
    private static func parseJSONL(
        data: Data,
        provider: UsageProvider,
        calendar: Calendar,
        into contributions: inout [String: [String: [String: PiPackedUsage]]])
    {
        guard let content = String(data: data, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            guard let usage = object["usage"] as? [String: Any] else { continue }

            let modelRaw: String
            if let modelObj = object["model"] as? [String: Any], let mid = modelObj["modelId"] as? String {
                modelRaw = mid
            } else if let mid = object["modelId"] as? String {
                modelRaw = mid
            } else if let modelStr = object["model"] as? String {
                modelRaw = modelStr
            } else {
                modelRaw = "unknown"
            }
            let modelName = CostUsagePricing.normalizeZaiModel(modelRaw)

            let startedAt: Date?
            if let ts = object["startedAt"] as? String {
                startedAt = self.parseTimestamp(ts)
            } else if let ts = object["completedAt"] as? String {
                startedAt = self.parseTimestamp(ts)
            } else {
                startedAt = nil
            }
            guard let date = startedAt else { continue }
            let dayKey = self.dayKey(from: date, calendar: calendar)

            let input = self.readInt(usage["inputTokens"] ?? usage["input_tokens"] ?? usage["input"])
            let output = self.readInt(usage["outputTokens"] ?? usage["output_tokens"] ?? usage["output"])
            let cacheRead = self.readInt(usage["cacheReadTokens"] ?? usage["cache_read_tokens"] ?? usage["cache_read"])
            let cacheWrite = self.readInt(usage["cacheWriteTokens"] ?? usage["cache_write_tokens"] ?? usage["cache_write"])
            let directTotal = self.readInt(usage["totalTokens"] ?? usage["total_tokens"])
            let totalTokens = max(directTotal, input + output + cacheRead + cacheWrite)

            let costUSD = CostUsagePricing.zaiCostUSD(
                model: modelName,
                inputTokens: input,
                cachedInputTokens: cacheRead,
                outputTokens: output,
                cacheWriteInputTokens: cacheWrite)
            let costNanos = costUSD.map { Int64(($0 * Self.costScale).rounded()) } ?? 0

            let packed = PiPackedUsage(
                inputTokens: input,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                outputTokens: output,
                totalTokens: totalTokens,
                costNanos: costNanos,
                costSampleCount: costUSD == nil ? 0 : 1,
                usageSampleCount: 1)

            let providerKey = provider.rawValue
            contributions[providerKey, default: [:]][dayKey, default: [:]][modelName, default: PiPackedUsage()].add(packed)
        }
    }

    // MARK: - workbuddy trace parsing

    /// Parses a workbuddy trace JSON file. Each file has one `trace` object with aggregated
    /// token totals under `trace.modelInfo` and a `trace.startedAt` timestamp.
    private static func parseWorkBuddyTrace(
        data: Data,
        provider: UsageProvider,
        calendar: Calendar,
        into contributions: inout [String: [String: [String: PiPackedUsage]]])
    {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trace = object["trace"] as? [String: Any]
        else { return }

        let modelInfo = trace["modelInfo"] as? [String: Any] ?? [:]
        let input = self.readInt(modelInfo["totalInputTokens"] ?? modelInfo["totalInputTokens"])
        let output = self.readInt(modelInfo["totalOutputTokens"] ?? modelInfo["totalOutputTokens"])
        let cached = self.readInt(modelInfo["totalCachedTokens"] ?? modelInfo["totalCachedTokens"])
        let directTotal = self.readInt(trace["totalTokens"] ?? modelInfo["totalTokens"])
        let totalTokens = max(directTotal, input + output + cached)

        // Model name: workbuddy's modelInfo.models is [String]; use first, or infer GLM-5.2.
        var modelName = "glm-5.2"
        if let models = modelInfo["models"] as? [String], let first = models.first {
            modelName = CostUsagePricing.normalizeZaiModel(first)
        }

        let date: Date?
        if let ts = trace["startedAt"] as? String {
            date = self.parseTimestamp(ts)
        } else if let ts = trace["endedAt"] as? String {
            date = self.parseTimestamp(ts)
        } else {
            date = nil
        }
        guard let dayDate = date else { return }
        let dayKey = self.dayKey(from: dayDate, calendar: calendar)

        let costUSD = CostUsagePricing.zaiCostUSD(
            model: modelName,
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output)
        let costNanos = costUSD.map { Int64(($0 * Self.costScale).rounded()) } ?? 0

        let packed = PiPackedUsage(
            inputTokens: input,
            cacheReadTokens: cached,
            cacheWriteTokens: 0,
            outputTokens: output,
            totalTokens: totalTokens,
            costNanos: costNanos,
            costSampleCount: costUSD == nil ? 0 : 1,
            usageSampleCount: 1)

        let providerKey = provider.rawValue
        contributions[providerKey, default: [:]][dayKey, default: [:]][modelName, default: PiPackedUsage()].add(packed)
    }

    // MARK: - Report building

    private static func buildReport(
        provider: UsageProvider,
        cache: ZCodeCostCache,
        since: Date,
        until: Date,
        calendar: Calendar) -> CostUsageDailyReport
    {
        guard let providerDays = cache.daysByProvider[provider.rawValue] else {
            return CostUsageDailyReport(data: [], summary: nil)
        }

        let sinceKey = self.dayKey(from: since, calendar: calendar)
        let untilKey = self.dayKey(from: until, calendar: calendar)
        let dayKeys = providerDays.keys.sorted().filter { $0 >= sinceKey && $0 <= untilKey }

        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCostNanos: Int64 = 0

        for dayKey in dayKeys {
            guard let models = providerDays[dayKey] else { continue }
            var dayInput = 0, dayOutput = 0, dayCacheRead = 0, dayCacheWrite = 0, dayTotalTokens = 0
            var dayCostNanos: Int64 = 0
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []

            for modelName in models.keys.sorted() {
                let packed = models[modelName] ?? PiPackedUsage()
                let modelTotal = max(packed.totalTokens,
                                     packed.inputTokens + packed.cacheReadTokens + packed.cacheWriteTokens + packed.outputTokens)
                let costUSD = Double(packed.costNanos) / Self.costScale
                breakdown.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: modelName,
                    costUSD: costUSD > 0 ? costUSD : nil,
                    totalTokens: modelTotal > 0 ? modelTotal : nil))
                dayInput += packed.inputTokens
                dayOutput += packed.outputTokens
                dayCacheRead += packed.cacheReadTokens
                dayCacheWrite += packed.cacheWriteTokens
                dayTotalTokens += modelTotal
                dayCostNanos += packed.costNanos
            }

            totalInput += dayInput
            totalOutput += dayOutput
            totalCacheRead += dayCacheRead
            totalCacheWrite += dayCacheWrite
            totalCostNanos += dayCostNanos

            entries.append(CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: dayInput > 0 ? dayInput : nil,
                outputTokens: dayOutput > 0 ? dayOutput : nil,
                cacheReadTokens: dayCacheRead > 0 ? dayCacheRead : nil,
                cacheCreationTokens: dayCacheWrite > 0 ? dayCacheWrite : nil,
                totalTokens: dayTotalTokens > 0 ? dayTotalTokens : nil,
                costUSD: dayCostNanos > 0 ? Double(dayCostNanos) / Self.costScale : nil,
                modelsUsed: models.keys.sorted(),
                modelBreakdowns: breakdown))
        }

        entries.sort { $0.date < $1.date }
        let summary = CostUsageDailyReport.Summary(
            totalInputTokens: totalInput > 0 ? totalInput : nil,
            totalOutputTokens: totalOutput > 0 ? totalOutput : nil,
            cacheReadTokens: totalCacheRead > 0 ? totalCacheRead : nil,
            cacheCreationTokens: totalCacheWrite > 0 ? totalCacheWrite : nil,
            totalTokens: (totalInput + totalOutput + totalCacheRead + totalCacheWrite) > 0
                ? (totalInput + totalOutput + totalCacheRead + totalCacheWrite) : nil,
            totalCostUSD: totalCostNanos > 0 ? Double(totalCostNanos) / Self.costScale : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }

    // MARK: - Helpers

    private static func pricingKey() -> String {
        CostUsagePricingKey.zai(formulaVersion: Self.costFormulaVersion)
    }

    private static func dayKey(from date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        return nil
    }

    private static func readInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            let numeric = number.doubleValue
            guard numeric.isFinite, numeric >= 0 else { return 0 }
            return Int(numeric.rounded())
        }
        if let string = value as? String,
           let numeric = Double(string),
           numeric.isFinite, numeric >= 0
        {
            return Int(numeric.rounded())
        }
        return 0
    }

    private static func mergeContributions(
        into daysByProvider: inout [String: [String: [String: PiPackedUsage]]],
        from contributions: [String: [String: [String: PiPackedUsage]]],
        sign: Int)
    {
        for (providerKey, days) in contributions {
            for (dayKey, models) in days {
                for (modelName, packed) in models {
                    var bucket = daysByProvider[providerKey, default: [:]][dayKey, default: [:]][modelName, default: PiPackedUsage()]
                    bucket.add(packed, sign: sign)
                    if bucket.isZero {
                        daysByProvider[providerKey]?[dayKey]?.removeValue(forKey: modelName)
                        if daysByProvider[providerKey]?[dayKey]?.isEmpty == true {
                            daysByProvider[providerKey]?.removeValue(forKey: dayKey)
                        }
                    } else {
                        daysByProvider[providerKey, default: [:]][dayKey, default: [:]][modelName] = bucket
                    }
                }
            }
        }
    }
}

// MARK: - PiPackedUsage additive merge

extension PiPackedUsage {
    fileprivate mutating func add(_ other: PiPackedUsage, sign: Int = 1) {
        let s = sign
        self.inputTokens = max(0, self.inputTokens + s * other.inputTokens)
        self.cacheReadTokens = max(0, self.cacheReadTokens + s * other.cacheReadTokens)
        self.cacheWriteTokens = max(0, self.cacheWriteTokens + s * other.cacheWriteTokens)
        self.outputTokens = max(0, self.outputTokens + s * other.outputTokens)
        self.totalTokens = max(0, self.totalTokens + s * other.totalTokens)
        self.costNanos = max(0, self.costNanos + Int64(s) * other.costNanos)
        self.costSampleCount = max(0, self.costSampleCount + s * other.costSampleCount)
        if let otherSamples = other.usageSampleCount {
            let current = self.usageSampleCount ?? 0
            self.usageSampleCount = max(0, current + s * otherSamples)
        }
    }
}
