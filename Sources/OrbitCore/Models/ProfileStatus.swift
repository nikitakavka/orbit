import Foundation

public struct ArrayProgressSummary: Equatable {
    public let parentJobID: String
    public let name: String
    public let done: Int
    public let total: Int
    public let running: Int
    public let pending: Int
}

public struct ProfileStatus {
    public let profile: ClusterProfile
    public let liveJobs: [JobSnapshot]
    public let lastSuccessfulPollAt: Date?
    public let sacctAvailable: Bool
    public let sacctNote: String?
    public let fairshareScore: Double?
    public let clusterLoad: ClusterLoad?
    public let clusterOverview: ClusterOverview?

    public var runningJobs: Int {
        liveJobs.filter { $0.state == .running }.count
    }

    public var pendingJobs: Int {
        liveJobs.filter { $0.state == .pending }.count
    }

    public var terminalJobs: Int {
        liveJobs.filter {
            switch $0.state {
            case .completed, .failed, .cancelled, .timeout, .outOfMemory:
                return true
            default:
                return false
            }
        }.count
    }

    public var arrayProgress: [ArrayProgressSummary] {
        let parents = liveJobs.filter { $0.isArray && $0.arrayTasksTotal > 0 }

        return parents.map { parent in
            let children = liveJobs.filter { $0.arrayParentID == parent.id && $0.id != parent.id }
            let running = children.filter { $0.state == .running }.count
            let pendingChildren = children.filter { $0.state == .pending }.count

            let total = max(parent.arrayTasksTotal, running + pendingChildren + parent.arrayTasksDone)
            let done = min(max(0, parent.arrayTasksDone), total)
            let inferredPending = max(0, total - done - running)
            let pending = max(pendingChildren, inferredPending)

            return ArrayProgressSummary(
                parentJobID: parent.id,
                name: parent.name,
                done: done,
                total: total,
                running: running,
                pending: pending
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.parentJobID < rhs.parentJobID }
            return lhs.name < rhs.name
        }
    }
}
