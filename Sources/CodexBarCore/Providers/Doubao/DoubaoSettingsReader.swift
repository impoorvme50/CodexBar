import Foundation

public struct DoubaoSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "ARK_API_KEY",
        "VOLCENGINE_API_KEY",
        "DOUBAO_API_KEY",
    ]
    public static let accessKeyIDEnvironmentKeys = [
        "VOLCENGINE_ACCESS_KEY_ID",
        "VOLCENGINE_ACCESS_KEY",
        "VOLC_ACCESSKEY",
        "DOUBAO_ACCESS_KEY_ID",
    ]
    public static let secretAccessKeyEnvironmentKeys = [
        "VOLCENGINE_SECRET_ACCESS_KEY",
        "VOLCENGINE_SECRET_KEY",
        "VOLCENGINE_ACCESS_KEY_SECRET",
        "VOLC_SECRETKEY",
        "DOUBAO_SECRET_ACCESS_KEY",
    ]
    public static let regionEnvironmentKeys = [
        "VOLCENGINE_REGION",
        "VOLCENGINE_REGION_ID",
        "VOLC_REGION",
        "DOUBAO_REGION",
    ]
    public static let defaultRegion = "cn-beijing"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.firstValue(in: environment, keys: self.apiKeyEnvironmentKeys)
    }

    public static func accessKeyID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.firstValue(in: environment, keys: self.accessKeyIDEnvironmentKeys)
    }

    public static func secretAccessKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.firstValue(in: environment, keys: self.secretAccessKeyEnvironmentKeys)
    }

    public static func region(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        self.firstValue(in: environment, keys: self.regionEnvironmentKeys) ?? self.defaultRegion
    }

    public static func codingPlanCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> DoubaoCodingPlanCredentials?
    {
        let accessKeyID = self.accessKeyID(environment: environment)
        let secretAccessKey = self.secretAccessKey(environment: environment)
        // Environment variables win when set; otherwise fall back to the CodexBar config
        // file so the menu-bar app can resolve credentials without env vars (GUI apps
        // launched from Dock/Spotlight do not inherit shell env vars).
        let resolvedAccessKeyID = accessKeyID ?? self.configFileAPIKey()
        let resolvedSecretAccessKey = secretAccessKey ?? self.configFileSecretKey()
        guard let resolvedAccessKeyID, let resolvedSecretAccessKey else {
            return nil
        }
        let region = self.firstValue(in: environment, keys: self.regionEnvironmentKeys)
            ?? self.configFileRegion()
            ?? self.defaultRegion
        return DoubaoCodingPlanCredentials(
            accessKeyID: resolvedAccessKeyID,
            secretAccessKey: resolvedSecretAccessKey,
            region: region)
    }

    /// Reads the Volcengine AccessKey ID for `.doubao` from the CodexBar config file.
    static func configFileAPIKey(
        store: CodexBarConfigStore = CodexBarConfigStore()) -> String?
    {
        guard let config = try? store.load() else { return nil }
        return config.providerConfig(for: .doubao)?.sanitizedAPIKey
    }

    /// Reads the Volcengine Secret Access Key for `.doubao` from the CodexBar config file.
    static func configFileSecretKey(
        store: CodexBarConfigStore = CodexBarConfigStore()) -> String?
    {
        guard let config = try? store.load() else { return nil }
        return config.providerConfig(for: .doubao)?.sanitizedSecretKey
    }

    /// Reads the region for `.doubao` from the CodexBar config file.
    static func configFileRegion(
        store: CodexBarConfigStore = CodexBarConfigStore()) -> String?
    {
        guard let config = try? store.load() else { return nil }
        return config.providerConfig(for: .doubao)?.sanitizedRegion
    }

    private static func firstValue(in environment: [String: String], keys: [String]) -> String? {
        for key in keys {
            guard let cleaned = self.cleaned(environment[key]) else { continue }
            return cleaned
        }
        return nil
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
