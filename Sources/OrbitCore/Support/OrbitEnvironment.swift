import Foundation

public enum OrbitEnvironment {
    public static let maxCommandOutputEnvKey = "ORBIT_MAX_COMMAND_OUTPUT_MB"
    public static let maxCommandOutputUserDefaultsKey = "orbit.maxCommandOutputMB"
    public static let defaultMaxCommandOutputMB = 500

    public static let enableAuditEnvKey = "ORBIT_ENABLE_AUDIT"
    public static let auditEnabledUserDefaultsKey = "orbit.auditEnabled"
    public static let defaultAuditEnabled = false

    public static func int(_ env: [String: String], key: String) -> Int? {
        guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Int(raw) else {
            return nil
        }
        return value
    }

    public static func bool(_ env: [String: String], key: String) -> Bool? {
        guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }

        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    public static func maxCommandOutputMB(
        env: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Int {
        if let fromEnv = int(env, key: maxCommandOutputEnvKey) {
            return max(1, fromEnv)
        }

        if userDefaults.object(forKey: maxCommandOutputUserDefaultsKey) != nil {
            let stored = userDefaults.integer(forKey: maxCommandOutputUserDefaultsKey)
            return max(1, stored)
        }

        return defaultMaxCommandOutputMB
    }

    public static func auditEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if let fromEnv = bool(env, key: enableAuditEnvKey) {
            return fromEnv
        }

        if userDefaults.object(forKey: auditEnabledUserDefaultsKey) != nil {
            return userDefaults.bool(forKey: auditEnabledUserDefaultsKey)
        }

        return defaultAuditEnabled
    }
}
