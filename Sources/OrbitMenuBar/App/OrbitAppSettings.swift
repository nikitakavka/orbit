import Foundation
import OrbitCore

enum OrbitAppSettings {
    static let cpuHourRateKey = "orbit.cpuHourRatePerHour"
    static let defaultCPUHourRate: Double = 0.02

    static func cpuHourRate(userDefaults: UserDefaults = .standard) -> Double {
        guard userDefaults.object(forKey: cpuHourRateKey) != nil else {
            return defaultCPUHourRate
        }

        let value = userDefaults.double(forKey: cpuHourRateKey)
        if value.isFinite {
            return max(0, value)
        }
        return defaultCPUHourRate
    }

    static func setCPUHourRate(_ value: Double, userDefaults: UserDefaults = .standard) {
        let safe = max(0, value.isFinite ? value : defaultCPUHourRate)
        userDefaults.set(safe, forKey: cpuHourRateKey)
    }

    static func maxCommandOutputMB(userDefaults: UserDefaults = .standard) -> Int {
        if userDefaults.object(forKey: OrbitEnvironment.maxCommandOutputUserDefaultsKey) == nil {
            return OrbitEnvironment.defaultMaxCommandOutputMB
        }

        let value = userDefaults.integer(forKey: OrbitEnvironment.maxCommandOutputUserDefaultsKey)
        return max(1, value)
    }

    static func setMaxCommandOutputMB(_ value: Int, userDefaults: UserDefaults = .standard) {
        let safe = max(1, value)
        userDefaults.set(safe, forKey: OrbitEnvironment.maxCommandOutputUserDefaultsKey)
    }

    static func auditEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: OrbitEnvironment.auditEnabledUserDefaultsKey) == nil {
            return OrbitEnvironment.defaultAuditEnabled
        }
        return userDefaults.bool(forKey: OrbitEnvironment.auditEnabledUserDefaultsKey)
    }

    static func setAuditEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: OrbitEnvironment.auditEnabledUserDefaultsKey)
    }
}
