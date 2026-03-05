import Foundation
import UserNotifications

public final class UserNotificationEngine: NotificationEngine {
    public enum EventType: String {
        case completed
        case failed
        case timeout
        case outOfMemory = "out_of_memory"
        case timeWarning = "time_warning"
    }

    private let database: OrbitDatabase
    private let inFlightLock = NSLock()
    private var inFlightNotificationIDs: Set<String> = []

    public init(database: OrbitDatabase) {
        self.database = database
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    public func process(diff: JobDiff, profile: ClusterProfile) {
        if profile.notifyOnComplete {
            // Queue-only completion policy:
            // notify when a job/array disappears from squeue (inferred finished),
            // not when individual tasks transiently flip to COMPLETED while still visible.
            for job in diff.inferredFinished {
                let arrayRoot = arrayRootID(for: job)
                guard wasSeenRunningBeforeDisappearance(job: job, arrayRootID: arrayRoot, profile: profile) else {
                    continue
                }

                let isArray = (arrayRoot != nil)
                sendIfNeeded(
                    event: .completed,
                    job: job,
                    dedupeJobID: arrayRoot,
                    profile: profile,
                    title: isArray ? "Array finished: \(job.name)" : "Finished: \(job.name)",
                    body: "No longer in queue on \(profile.displayName)"
                )
            }
        }

        if profile.notifyOnFail {
            for job in diff.newlyFailed {
                sendIfNeeded(
                    event: .failed,
                    job: job,
                    profile: profile,
                    title: "Failed: \(job.name)",
                    body: "Failed after \(durationText(job.timeUsed)) on \(profile.displayName)"
                )
            }

            for job in diff.newlyTimedOut {
                sendIfNeeded(
                    event: .timeout,
                    job: job,
                    profile: profile,
                    title: "Timed out: \(job.name)",
                    body: "Hit time limit on \(profile.displayName)"
                )
            }

            for job in diff.newlyOutOfMemory {
                sendIfNeeded(
                    event: .outOfMemory,
                    job: job,
                    profile: profile,
                    title: "Out of memory: \(job.name)",
                    body: "Out of memory on \(profile.displayName)"
                )
            }
        }

        if profile.notifyOnTimeWarningMinutes > 0 {
            for job in diff.approachingTimeLimit {
                sendIfNeeded(
                    event: .timeWarning,
                    job: job,
                    profile: profile,
                    title: "Time warning: \(job.name)",
                    body: "\(profile.notifyOnTimeWarningMinutes) minutes remaining on \(profile.displayName)"
                )
            }
        }
    }

    private func sendIfNeeded(
        event: EventType,
        job: JobSnapshot,
        dedupeJobID: String? = nil,
        profile: ClusterProfile,
        title: String,
        body: String
    ) {
        let jobID = dedupeJobID ?? job.id
        let alreadyFired = (try? database.notificationAlreadyFired(jobId: jobID, profileId: profile.id, eventType: event.rawValue)) ?? false
        guard !alreadyFired else { return }

        let requestID = "orbit.\(profile.id.uuidString).\(jobID).\(event.rawValue)"
        guard beginInFlight(requestID) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let self else { return }
            defer { self.endInFlight(requestID) }

            guard error == nil else { return }
            try? self.database.markNotificationFired(jobId: jobID, profileId: profile.id, eventType: event.rawValue)
        }
    }

    private func beginInFlight(_ requestID: String) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }

        if inFlightNotificationIDs.contains(requestID) {
            return false
        }

        inFlightNotificationIDs.insert(requestID)
        return true
    }

    private func endInFlight(_ requestID: String) {
        inFlightLock.lock()
        inFlightNotificationIDs.remove(requestID)
        inFlightLock.unlock()
    }

    private func arrayRootID(for job: JobSnapshot) -> String? {
        if job.isArray, job.arrayTasksTotal > 0 {
            return job.id
        }

        if let parentID = job.arrayParentID, parentID != job.id {
            return parentID
        }

        return inferredArrayParentIDFromJobID(job.id)
    }

    private func wasSeenRunningBeforeDisappearance(
        job: JobSnapshot,
        arrayRootID: String?,
        profile: ClusterProfile
    ) -> Bool {
        do {
            if let arrayRootID {
                return try database.arrayWasSeenRunning(profileId: profile.id, arrayRootId: arrayRootID)
            }
            return try database.jobWasSeenRunning(profileId: profile.id, jobId: job.id)
        } catch {
            return false
        }
    }

    private func inferredArrayParentIDFromJobID(_ jobID: String) -> String? {
        guard let underscore = jobID.firstIndex(of: "_") else { return nil }
        let prefix = String(jobID[..<underscore])
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return prefix
    }

    private func durationText(_ time: TimeInterval) -> String {
        let total = Int(time)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
