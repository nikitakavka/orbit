import Foundation
import OrbitCore

struct OrbitMenuBarRuntime {
    let service: OrbitService
    let notificationsEnabled: Bool

    static func make() throws -> OrbitMenuBarRuntime {
        let env = ProcessInfo.processInfo.environment
        let dbPath = env["ORBIT_DB_PATH"] ?? OrbitDatabase.defaultPath()

        let database = try OrbitDatabase(
            path: dbPath,
            auditRetentionDays: OrbitEnvironment.int(env, key: "ORBIT_AUDIT_RETENTION_DAYS") ?? 8,
            historyRetentionDays: OrbitEnvironment.int(env, key: "ORBIT_HISTORY_RETENTION_DAYS") ?? 8,
            notificationRetentionDays: OrbitEnvironment.int(env, key: "ORBIT_NOTIFICATION_RETENTION_DAYS") ?? 8,
            maxHistoryEntriesPerPoll: OrbitEnvironment.int(env, key: "ORBIT_MAX_HISTORY_ENTRIES_PER_POLL") ?? 2_000,
            maxDatabaseSizeMB: OrbitEnvironment.int(env, key: "ORBIT_MAX_DB_SIZE_MB") ?? 200
        )

        let notificationsEnabled = env["ORBIT_ENABLE_NOTIFICATIONS"] != "0"
        let notificationEngine: NotificationEngine = notificationsEnabled
            ? UserNotificationEngine(database: database)
            : NoopNotificationEngine()

        let service = OrbitService(database: database, notificationEngine: notificationEngine)
        return OrbitMenuBarRuntime(service: service, notificationsEnabled: notificationsEnabled)
    }
}
