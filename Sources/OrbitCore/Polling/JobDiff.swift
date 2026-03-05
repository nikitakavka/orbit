import Foundation

public struct JobDiff {
    public let newlyCompleted: [JobSnapshot]
    public let newlyFailed: [JobSnapshot]
    public let newlyTimedOut: [JobSnapshot]
    public let newlyOutOfMemory: [JobSnapshot]
    public let inferredFinished: [JobSnapshot]
    public let approachingTimeLimit: [JobSnapshot]
    public let newlyStarted: [JobSnapshot]
    public let newlyPending: [JobSnapshot]

    public static let empty = JobDiff(
        newlyCompleted: [],
        newlyFailed: [],
        newlyTimedOut: [],
        newlyOutOfMemory: [],
        inferredFinished: [],
        approachingTimeLimit: [],
        newlyStarted: [],
        newlyPending: []
    )
}

public enum JobDiffer {
    public static func diff(previous: [JobSnapshot], current: [JobSnapshot], warningMinutes: Int = 15) -> JobDiff {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let warningSeconds = TimeInterval(warningMinutes * 60)

        var completed: [JobSnapshot] = []
        var failed: [JobSnapshot] = []
        var timedOut: [JobSnapshot] = []
        var oom: [JobSnapshot] = []
        var inferredFinished: [JobSnapshot] = []
        var warn: [JobSnapshot] = []
        var started: [JobSnapshot] = []
        var pending: [JobSnapshot] = []

        for job in current {
            let prev = oldByID[job.id]
            if prev?.state != .running, job.state == .running { started.append(job) }
            if prev?.state != .pending, job.state == .pending { pending.append(job) }

            if let limit = job.timeLimit, job.state == .running {
                let remaining = limit - job.timeUsed
                if remaining > 0, remaining <= warningSeconds { warn.append(job) }
            }

            guard let prev, prev.state != job.state else { continue }
            switch job.state {
            case .completed: completed.append(job)
            case .failed: failed.append(job)
            case .timeout: timedOut.append(job)
            case .outOfMemory: oom.append(job)
            default: break
            }
        }

        inferredFinished = inferredFinishedJobs(previousByID: oldByID, current: current, currentByID: currentByID)

        return JobDiff(
            newlyCompleted: completed,
            newlyFailed: failed,
            newlyTimedOut: timedOut,
            newlyOutOfMemory: oom,
            inferredFinished: inferredFinished,
            approachingTimeLimit: warn,
            newlyStarted: started,
            newlyPending: pending
        )
    }

    private static func inferredFinishedJobs(
        previousByID: [String: JobSnapshot],
        current: [JobSnapshot],
        currentByID: [String: JobSnapshot]
    ) -> [JobSnapshot] {
        let currentArrayParentIDs = Set(current.compactMap { inferredArrayParentID(for: $0) })

        var handledArrayParents: Set<String> = []
        var inferred: [JobSnapshot] = []

        let missingJobs = previousByID.values
            .filter { currentByID[$0.id] == nil }
            .sorted { $0.id < $1.id }

        for job in missingJobs {
            if let arrayParentID = inferredArrayParentID(for: job) {
                if currentArrayParentIDs.contains(arrayParentID) || currentByID[arrayParentID] != nil {
                    continue
                }

                guard handledArrayParents.insert(arrayParentID).inserted else { continue }
                inferred.append(previousByID[arrayParentID] ?? job)
                continue
            }

            if shouldInferFinishedOnDisappearance(state: job.state) {
                inferred.append(job)
            }
        }

        return inferred
    }

    private static func inferredArrayParentID(for job: JobSnapshot) -> String? {
        if job.isArray, job.arrayTasksTotal > 0 {
            return job.id
        }

        if let parentID = job.arrayParentID, parentID != job.id {
            return parentID
        }

        return inferredArrayParentIDFromJobID(job.id)
    }

    private static func inferredArrayParentIDFromJobID(_ jobID: String) -> String? {
        guard let underscore = jobID.firstIndex(of: "_") else { return nil }
        let prefix = String(jobID[..<underscore])
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return prefix
    }

    private static func shouldInferFinishedOnDisappearance(state: JobState) -> Bool {
        switch state {
        case .pending, .running, .completing, .completed, .unknown:
            return true
        case .failed, .cancelled, .timeout, .outOfMemory:
            return false
        }
    }
}
