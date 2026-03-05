import Foundation
import OrbitCore

extension OrbitMenuBarViewModel {
    func computeIndicator(from statuses: [ProfileStatus]) -> Indicator {
        guard !statuses.isEmpty else { return .disconnected }

        let hasAnySuccessfulPoll = statuses.contains { $0.lastSuccessfulPollAt != nil }
        guard hasAnySuccessfulPoll else { return .disconnected }

        let now = Date()
        let allStale = statuses.allSatisfy { status in
            guard let last = status.lastSuccessfulPollAt else { return true }
            let staleAfter = max(status.profile.pollIntervalSeconds * 2, 120)
            return now.timeIntervalSince(last) > TimeInterval(staleAfter)
        }
        if allStale { return .disconnected }

        let jobs = statuses.flatMap(\.liveJobs)

        if jobs.contains(where: { $0.state == .failed || $0.state == .timeout || $0.state == .outOfMemory }) {
            return .failure
        }

        if jobs.contains(where: isWarning) {
            return .warning
        }

        if jobs.contains(where: { $0.state == .pending }) {
            return .pending
        }

        return .healthy
    }

    func effectiveTimeUsed(_ job: JobSnapshot) -> TimeInterval {
        max(0, job.timeUsed)
    }

    func isWarning(_ job: JobSnapshot) -> Bool {
        guard job.state == .running, let limit = job.timeLimit, limit > 0 else { return false }
        let used = effectiveTimeUsed(job)
        let remaining = limit - used
        if remaining <= 0 { return true }

        if remaining <= 15 * 60 { return true }
        return (remaining / limit) <= 0.25
    }

    func progress(_ job: JobSnapshot) -> Double? {
        guard let limit = job.timeLimit, limit > 0 else { return nil }
        let used = effectiveTimeUsed(job)
        return min(1.0, max(0.0, used / limit))
    }

    func paddedCPUHistory(lastHours: Int) -> [CPUCoreDataPoint] {
        guard let profileId = selectedStatus?.profile.id else { return [] }

        let now = Date()
        let start = now.addingTimeInterval(TimeInterval(-max(1, lastHours) * 60 * 60))

        let sorted = cpuHistory
            .filter { $0.timestamp >= start }
            .sorted { $0.timestamp < $1.timestamp }

        if sorted.isEmpty {
            return [
                CPUCoreDataPoint(profileId: profileId, timestamp: start, totalCoresInUse: 0),
                CPUCoreDataPoint(profileId: profileId, timestamp: now, totalCoresInUse: 0)
            ]
        }

        var result: [CPUCoreDataPoint] = []

        if let first = sorted.first, first.timestamp > start {
            result.append(CPUCoreDataPoint(profileId: profileId, timestamp: start, totalCoresInUse: 0))

            let preFirst = first.timestamp.addingTimeInterval(-1)
            if preFirst > start {
                result.append(CPUCoreDataPoint(profileId: profileId, timestamp: preFirst, totalCoresInUse: 0))
            }
        }

        result.append(contentsOf: sorted)

        if let last = sorted.last, last.timestamp < now {
            result.append(CPUCoreDataPoint(profileId: profileId, timestamp: now, totalCoresInUse: max(0, last.totalCoresInUse)))
        }

        return result
    }
}
