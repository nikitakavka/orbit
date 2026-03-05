import Foundation
import OrbitCore

enum OrbitMenuBarJobGrouping {
    static func arrayGroups(from status: ProfileStatus) -> [OrbitMenuBarViewModel.ArrayRunningGroup] {
        let jobs = status.liveJobs
        var groupsByParentID: [String: OrbitMenuBarViewModel.ArrayRunningGroup] = [:]

        for summary in status.arrayProgress where summary.total > 0 {
            if summary.running <= 0 && summary.pending <= 0 { continue }

            let children = jobs
                .filter { $0.arrayParentID == summary.parentJobID && $0.id != summary.parentJobID }

            let runningChildren = children
                .filter { $0.state == .running || $0.state == .completing }
                .sorted(by: runningJobUrgency)

            let representative = jobs.first(where: { $0.id == summary.parentJobID }) ?? runningChildren.first
            let taskStats = arrayTaskIDStats(children: children, parentJobID: summary.parentJobID)
            let total = max(summary.total, taskStats?.observedTaskCount ?? 0)

            var done = min(summary.done, total)
            if let taskStats {
                let inferredDone = max(0, taskStats.observedTaskCount - summary.running - summary.pending)
                done = min(total, max(done, inferredDone))
            }

            groupsByParentID[summary.parentJobID] = OrbitMenuBarViewModel.ArrayRunningGroup(
                parentJobID: summary.parentJobID,
                name: summary.name,
                done: done,
                total: total,
                running: summary.running,
                pending: summary.pending,
                runningChildren: runningChildren,
                representativeJob: representative
            )
        }

        // Fallback grouping for clusters where squeue doesn't expose the parent array summary row.
        let orphanChildren = jobs.filter { job in
            guard let parent = job.arrayParentID else { return false }
            return parent != job.id
        }

        let groupedChildren = Dictionary(grouping: orphanChildren, by: { $0.arrayParentID ?? "" })
        for (parentJobID, children) in groupedChildren where !parentJobID.isEmpty {
            guard groupsByParentID[parentJobID] == nil else { continue }

            let runningChildren = children
                .filter { $0.state == .running || $0.state == .completing }
                .sorted(by: runningJobUrgency)

            let running = runningChildren.count
            let pending = children.filter { $0.state == .pending }.count
            if running <= 0 && pending <= 0 { continue }

            let completedCount = children.filter {
                switch $0.state {
                case .completed, .failed, .cancelled, .timeout, .outOfMemory:
                    return true
                default:
                    return false
                }
            }.count

            let taskStats = arrayTaskIDStats(children: children, parentJobID: parentJobID)
            let total = max(children.count, running + pending + completedCount, taskStats?.observedTaskCount ?? 0)
            let representative = jobs.first(where: { $0.id == parentJobID }) ?? runningChildren.first ?? children.first

            var done = completedCount
            if let taskStats {
                let inferredDone = max(0, taskStats.observedTaskCount - running - pending)
                done = max(done, inferredDone)
            }

            groupsByParentID[parentJobID] = OrbitMenuBarViewModel.ArrayRunningGroup(
                parentJobID: parentJobID,
                name: representative?.name ?? "array_\(parentJobID)",
                done: min(total, max(0, done)),
                total: max(1, total),
                running: running,
                pending: pending,
                runningChildren: runningChildren,
                representativeJob: representative
            )
        }

        return groupsByParentID.values.sorted { lhs, rhs in
            if lhs.running != rhs.running { return lhs.running > rhs.running }
            if lhs.pending != rhs.pending { return lhs.pending > rhs.pending }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func singleRunningJobs(from status: ProfileStatus, groupedArrayParentIDs: Set<String>) -> [JobSnapshot] {
        status.liveJobs
            .filter { $0.state == .running || $0.state == .completing }
            .filter { job in
                if groupedArrayParentIDs.contains(job.id) { return false }
                if let parent = job.arrayParentID, parent != job.id { return false }
                if job.isArray { return false }
                return true
            }
            .sorted(by: runningJobUrgency)
    }

    static func pendingJobs(from status: ProfileStatus, groupedArrayParentIDs: Set<String>) -> [JobSnapshot] {
        status.liveJobs
            .filter { $0.state == .pending }
            .filter { job in
                if let parent = job.arrayParentID, parent != job.id { return false }
                if groupedArrayParentIDs.contains(job.id) { return false }
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func isActiveState(_ state: JobState) -> Bool {
        switch state {
        case .running, .completing, .pending:
            return true
        default:
            return false
        }
    }

    private struct ArrayTaskIDStats {
        let observedTaskCount: Int
    }

    private static func arrayTaskIDStats(children: [JobSnapshot], parentJobID: String) -> ArrayTaskIDStats? {
        let taskIDs = Set(children.compactMap { resolvedArrayTaskID(for: $0, parentJobID: parentJobID) })
        guard !taskIDs.isEmpty else { return nil }
        return ArrayTaskIDStats(observedTaskCount: taskIDs.count)
    }

    private static func resolvedArrayTaskID(for job: JobSnapshot, parentJobID: String) -> Int? {
        if let explicit = job.arrayTaskID {
            return explicit
        }

        return OrbitArrayTaskIDResolver.int(fromJobID: job.id, parentJobID: parentJobID)
    }

    private static func runningJobUrgency(_ lhs: JobSnapshot, _ rhs: JobSnapshot) -> Bool {
        let leftRemaining = lhs.timeLimit.map { $0 - lhs.timeUsed } ?? .infinity
        let rightRemaining = rhs.timeLimit.map { $0 - rhs.timeUsed } ?? .infinity

        if leftRemaining == rightRemaining {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return leftRemaining < rightRemaining
    }
}
