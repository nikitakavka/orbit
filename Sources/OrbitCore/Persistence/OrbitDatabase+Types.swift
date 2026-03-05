import Foundation
@preconcurrency import GRDB

public struct AuditLogEntry: FetchableRecord, Decodable {
    public let id: Int64
    public let timestamp: String
    public let profile_id: String
    public let cluster_name: String
    public let command: String
    public let exit_code: Int?
    public let duration_ms: Int?
    public let error: String?
    public let parse_failed: Int
}

public struct OrbitStorageStats: Equatable {
    public let fileSizeBytes: Int64
    public let profileCount: Int
    public let livePollBatchCount: Int
    public let jobSnapshotCount: Int
    public let jobHistoryCount: Int
    public let auditLogCount: Int
    public let notificationStateCount: Int

    public let auditRetentionDays: Int
    public let historyRetentionDays: Int
    public let notificationRetentionDays: Int
    public let maxHistoryEntriesPerPoll: Int
    public let maxDatabaseSizeBytes: Int64
}

public enum OrbitDatabaseError: Error, LocalizedError {
    case profileNotFound(String)
    case ambiguousProfileName(String)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let value):
            return "Cluster profile not found: \(value)"
        case .ambiguousProfileName(let value):
            return "Profile name is ambiguous: \(value). Use profile UUID instead."
        }
    }
}
