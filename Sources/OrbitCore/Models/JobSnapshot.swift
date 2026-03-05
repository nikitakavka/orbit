import Foundation

public struct JobSnapshot: Codable, Identifiable, Equatable {
    public let id: String
    public let profileId: UUID
    public var name: String
    public var state: JobState
    public var partition: String
    public var nodes: Int
    public var cpus: Int
    public var nodeList: String? = nil
    public var memoryRequestedMB: Int? = nil
    public var gpuCount: Int? = nil
    public var workingDirectory: String? = nil
    public var timeUsed: TimeInterval
    public var timeLimit: TimeInterval?
    public var submitTime: Date?
    public var startTime: Date?
    public var estimatedStartTime: Date?
    public var pendingReason: String?
    public var isArray: Bool
    public var arrayParentID: String? = nil
    public var arrayTaskID: Int? = nil
    public var arrayTasksDone: Int
    public var arrayTasksTotal: Int
    public var snapshotTime: Date
}

public struct JobHistorySnapshot: Codable, Identifiable, Equatable {
    public let id: String
    public let profileId: UUID
    public var name: String
    public var state: JobState
    public var exitCode: String?
    public var elapsed: TimeInterval
    public var timeLimit: TimeInterval?
    public var cpuTimeUsed: TimeInterval
    public var cpusRequested: Int
    public var maxRSS: Int64?
    public var memoryRequested: Int64?
    public var startTime: Date?
    public var endTime: Date?

    public var cpuEfficiency: Double? {
        guard cpuTimeUsed > 0, elapsed > 0, cpusRequested > 0 else { return nil }
        return cpuTimeUsed / (elapsed * Double(cpusRequested))
    }

    public var memoryEfficiency: Double? {
        guard let maxRSS, let memoryRequested, memoryRequested > 0 else { return nil }
        return Double(maxRSS) / Double(memoryRequested)
    }
}

public struct ClusterLoad: Codable, Equatable {
    public let profileId: UUID
    public var totalCPUs: Int
    public var allocatedCPUs: Int
    public var totalNodes: Int
    public var allocatedNodes: Int
    public var fetchedAt: Date

    public var cpuLoadPercent: Double {
        guard totalCPUs > 0 else { return 0 }
        return Double(allocatedCPUs) / Double(totalCPUs) * 100
    }
}

public struct CPUCoreDataPoint: Codable, Equatable {
    public let profileId: UUID
    public let timestamp: Date
    public let totalCoresInUse: Int

    public init(profileId: UUID, timestamp: Date, totalCoresInUse: Int) {
        self.profileId = profileId
        self.timestamp = timestamp
        self.totalCoresInUse = totalCoresInUse
    }
}
