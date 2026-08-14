import Foundation

public struct LivePollResult {
    public let jobs: [JobSnapshot]
    public let error: String?
    public let usedStaleData: Bool
    public let parseFailed: Bool
    public let lastSuccessfulPollAt: Date?

    public var staleAgeSeconds: Int? {
        guard usedStaleData, let lastSuccessfulPollAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(lastSuccessfulPollAt)))
    }
}

public final class PollEngine {
    public let profile: ClusterProfile
    public let connection: SSHConnection
    public let database: OrbitDatabase
    public let notificationEngine: NotificationEngine

    private let commandBuilder: SlurmCommandBuilder
    private let jsonParser = JSONSlurmParser()

    private struct ArrayFallbackRetry {
        var failures: Int
        var nextAttemptAt: Date
    }

    struct ArrayAccountingCoverage {
        var all: [String: IndexSet] = [:]
        var finished: [String: IndexSet] = [:]
    }

    private let stateLock = NSLock()
    private var inFlightEstimatedStartFetches: Set<String> = []
    private var arrayFallbackRetries: [String: ArrayFallbackRetry] = [:]
    private var arraysWithoutScriptMetadata: Set<String> = []
    private var lastUnavailableAccountingProbeAt: Date?
    private var isExtendedPollInFlight = false

    private let maxEstimatedStartFetchesPerPoll = 5
    private let unavailableAccountingRetryInterval: TimeInterval = 60 * 60
    private let maxBatchScriptOutputBytes = 256 * 1024

    public init(
        profile: ClusterProfile,
        connection: SSHConnection,
        database: OrbitDatabase,
        notificationEngine: NotificationEngine = NoopNotificationEngine()
    ) throws {
        self.profile = profile
        self.connection = connection
        self.database = database
        self.notificationEngine = notificationEngine
        self.commandBuilder = try SlurmCommandBuilder(mode: profile.outputMode, username: profile.username)
    }

    @discardableResult
    public func runLivePoll() async -> LivePollResult {
        let command = commandBuilder.squeueCommand

        let commandResult = await runLogged(command: command)
        switch commandResult {
        case .failure(let error):
            let previous = loadLatestLiveOrEmpty()
            let lastSuccess = loadLastSuccessfulLivePollAt()
            return LivePollResult(
                jobs: previous,
                error: error.localizedDescription,
                usedStaleData: !previous.isEmpty,
                parseFailed: false,
                lastSuccessfulPollAt: lastSuccess
            )

        case .success(let result, let auditId):
            let previous = loadLatestLiveOrEmpty()
            let parse = parseJobsWithFallback(result.stdout)

            if parse.parseFailed {
                var parseError = "Failed to parse squeue output"
                if let auditId {
                    do {
                        try database.markParseFailure(id: auditId, rawOutput: result.stdout)
                    } catch {
                        parseError += " (audit write failed: \(error.localizedDescription))"
                        reportInternalError("marking parse failure for live poll", error: error)
                    }
                }

                return LivePollResult(
                    jobs: previous,
                    error: parseError,
                    usedStaleData: !previous.isEmpty,
                    parseFailed: true,
                    lastSuccessfulPollAt: loadLastSuccessfulLivePollAt()
                )
            }

            let jobs = reconcileArrayProgress(
                jobs: parse.jobs,
                previous: previous
            )
            do {
                try database.saveLive(jobs, profileId: profile.id)
            } catch {
                return LivePollResult(
                    jobs: jobs,
                    error: "Saved poll data partially: \(error.localizedDescription)",
                    usedStaleData: false,
                    parseFailed: false,
                    lastSuccessfulPollAt: nil
                )
            }

            let diff = JobDiffer.diff(previous: previous, current: jobs, warningMinutes: profile.notifyOnTimeWarningMinutes)
            notificationEngine.process(diff: diff, profile: profile)

            var queuedEstimatedStartFetches = 0
            for job in diff.newlyPending {
                guard queuedEstimatedStartFetches < maxEstimatedStartFetchesPerPoll else { break }
                queuedEstimatedStartFetches += 1

                Task { [weak self] in
                    await self?.fetchEstimatedStart(jobId: job.id)
                }
            }

            if !diff.newlyCompleted.isEmpty || !diff.newlyFailed.isEmpty || !diff.newlyTimedOut.isEmpty || !diff.newlyOutOfMemory.isEmpty || !diff.inferredFinished.isEmpty {
                triggerExtendedPollIfNeeded(afterTerminalDiff: true)
            }

            return LivePollResult(
                jobs: jobs,
                error: nil,
                usedStaleData: false,
                parseFailed: false,
                lastSuccessfulPollAt: Date()
            )
        }
    }

    public func runExtendedPoll(onClusterResourcesUpdated: (() -> Void)? = nil) async {
        guard beginExtendedPoll() else { return }
        defer { endExtendedPoll() }

        // Cluster capacity is visible in the main popover, so fetch it first and
        // let the UI refresh before the auxiliary history/fairshare commands.
        _ = await runClusterLoadPoll()
        onClusterResourcesUpdated?()

        if profile.fairshareEnabled {
            _ = await runFairsharePoll()
        }

        let cachedSacctAvailability: Bool
        do {
            cachedSacctAvailability = try database.isSacctAvailable(profileId: profile.id)
        } catch {
            reportInternalError("reading sacct capability", error: error)
            cachedSacctAvailability = true
        }

        // A previous failure is not permanent: cluster accounting can be
        // enabled later, so probe once per app session and then hourly.
        if shouldProbeAccounting(cachedAvailable: cachedSacctAvailability) {
            _ = await runSacctPoll()
        }

        if (try? database.isSacctAvailable(profileId: profile.id)) != false {
            _ = await runArrayAccountingPoll()
        } else {
            _ = await runArrayMetadataFallback(for: currentArrayParents())
        }
    }

    public func fetchEstimatedStart(jobId: String) async {
        guard beginEstimatedStartFetch(jobId: jobId) else { return }
        defer { endEstimatedStartFetch(jobId: jobId) }

        let cmd: String
        do {
            cmd = try commandBuilder.estimatedStartCommand(jobId: jobId)
        } catch {
            reportInternalError("building estimated-start command for job \(jobId)", error: error)
            return
        }

        let commandResult = await runLogged(command: cmd)
        guard case let .success(result, _) = commandResult else { return }

        let date = jsonParser.parseEstimatedStart(result.stdout)
        do {
            try database.updateEstimatedStart(date: date, jobId: jobId, profileId: profile.id)
        } catch {
            reportInternalError("persisting estimated start for job \(jobId)", error: error)
        }
    }

    private func reconcileArrayProgress(
        jobs: [JobSnapshot],
        previous: [JobSnapshot]
    ) -> [JobSnapshot] {
        var reconciled = jobs
        let parentIndices = reconciled.indices.filter {
            reconciled[$0].isArray && reconciled[$0].arrayTasksTotal > 0
        }
        let parentIDs = parentIndices.map { reconciled[$0].id }
        guard !parentIDs.isEmpty else { return reconciled }

        let records: [String: ArrayProgressRecord]
        do {
            records = try database.arrayProgressRecords(
                profileId: profile.id,
                parentJobIDs: parentIDs
            )
        } catch {
            reportInternalError("loading array progress", error: error)
            return reconciled
        }

        let previousByID = previous.reduce(into: [String: JobSnapshot]()) { result, job in
            result[job.id] = job
        }

        for index in parentIndices {
            let parentID = reconciled[index].id
            let observedTotal = max(0, reconciled[index].arrayTasksTotal)
            let reportedFinished = min(observedTotal, max(0, reconciled[index].arrayTasksDone))
            let activeTaskCount = max(0, observedTotal - reportedFinished)
            let previousParent = previousByID[parentID]
            let record = records[parentID]

            var stableTotal = observedTotal
            var totalSource = reconciled[index].arrayTasksTotalSource ?? .observedQueue
            var totalIsExact = reconciled[index].arrayTasksTotalIsExact == true

            func considerTotal(
                _ candidateTotal: Int,
                source candidateSource: ArrayProgressTotalSource,
                exact candidateIsExact: Bool
            ) {
                let safeCandidate = max(0, candidateTotal)
                if candidateSource.rawValue > totalSource.rawValue {
                    stableTotal = safeCandidate
                    totalSource = candidateSource
                    totalIsExact = candidateIsExact
                } else if candidateSource == totalSource {
                    stableTotal = max(stableTotal, safeCandidate)
                    totalIsExact = totalIsExact || candidateIsExact
                } else if safeCandidate > stableTotal {
                    // A lower-confidence live observation is still a hard lower bound.
                    stableTotal = safeCandidate
                }
            }

            if let record {
                considerTotal(record.total, source: record.totalSource, exact: record.totalIsExact)
            }
            if let previousParent {
                considerTotal(
                    previousParent.arrayTasksTotal,
                    source: previousParent.arrayTasksTotalSource ?? .observedQueue,
                    exact: previousParent.arrayTasksTotalIsExact == true
                )
            }
            if let submittedTotal = reconciled[index].arraySubmittedTasksTotal {
                considerTotal(submittedTotal, source: .submitLine, exact: true)
            }

            stableTotal = max(stableTotal, activeTaskCount)
            let inferredFinished = totalIsExact ? max(0, stableTotal - activeTaskCount) : 0
            let stableFinished = min(stableTotal, max(
                reportedFinished,
                inferredFinished,
                record?.finished ?? 0,
                previousParent?.arrayTasksDone ?? 0
            ))
            var finishedSource = record?.finishedSource ?? .observedQueue
            if inferredFinished >= stableFinished, totalIsExact {
                finishedSource = maxFinishedSource(finishedSource, .inferredFromQueue)
            }

            do {
                let merged = try database.mergeArrayProgress(
                    profileId: profile.id,
                    parentJobID: parentID,
                    total: stableTotal,
                    finished: stableFinished,
                    totalIsExact: totalIsExact,
                    totalSource: totalSource,
                    finishedSource: finishedSource
                )
                stableTotal = max(stableTotal, merged.total)
                totalSource = merged.totalSource
                totalIsExact = totalIsExact || merged.totalIsExact

                reconciled[index].arrayTasksDone = min(
                    stableTotal,
                    max(stableFinished, merged.finished)
                )
            } catch {
                reportInternalError("saving array progress for \(parentID)", error: error)
                reconciled[index].arrayTasksDone = stableFinished
            }

            reconciled[index].arrayTasksTotal = stableTotal
            reconciled[index].arrayTasksTotalIsExact = totalIsExact
            reconciled[index].arrayTasksTotalSource = totalSource
        }

        return reconciled
    }

    @discardableResult
    private func runSacctPoll() async -> Bool {
        let commandResult = await runLogged(command: commandBuilder.sacctCommand)

        switch commandResult {
        case .failure(let error):
            if isAccountingStorageDisabled(error.localizedDescription) {
                do {
                    try database.setSacctAvailability(
                        profileId: profile.id,
                        available: false,
                        note: "Slurm accounting storage is disabled"
                    )
                } catch {
                    reportInternalError("updating sacct availability=false", error: error)
                }
            }
            return false

        case .success(let result, let auditId):
            do {
                try database.setSacctAvailability(profileId: profile.id, available: true)
            } catch {
                reportInternalError("updating sacct availability=true", error: error)
            }

            do {
                let parsed = try jsonParser.parseJobHistory(result.stdout, profileId: profile.id)
                do {
                    try database.saveHistory(parsed, profileId: profile.id)
                    return true
                } catch {
                    reportInternalError("saving sacct history", error: error)
                    return false
                }
            } catch {
                if let auditId {
                    do {
                        try database.markParseFailure(id: auditId, rawOutput: result.stdout)
                    } catch {
                        reportInternalError("marking sacct parse failure", error: error)
                    }
                }
                return false
            }
        }
    }

    @discardableResult
    private func runArrayAccountingPoll() async -> Bool {
        let parents = currentArrayParents()
        guard !parents.isEmpty else { return true }

        let parentByID = Dictionary(uniqueKeysWithValues: parents.map { ($0.id, $0) })
        var accountedParentIDs: Set<String> = []
        var accountingSucceeded = true
        var accountingDisabled = false

        for parentIDBatch in parentByID.keys.sorted().chunked(maxCount: 50) {
            let command: String
            do {
                command = try commandBuilder.arrayAccountingCommand(arrayJobIds: parentIDBatch)
            } catch {
                reportInternalError("building array accounting command", error: error)
                accountingSucceeded = false
                continue
            }

            let commandResult = await runLogged(command: command)
            switch commandResult {
            case .failure(let error):
                accountingSucceeded = false
                if isAccountingStorageDisabled(error.localizedDescription) {
                    accountingDisabled = true
                    do {
                        try database.setSacctAvailability(
                            profileId: profile.id,
                            available: false,
                            note: "Slurm accounting storage is disabled"
                        )
                    } catch {
                        reportInternalError("updating array accounting capability", error: error)
                    }
                }

            case .success(let result, let auditId):
                let history: [JobHistorySnapshot]
                do {
                    history = try jsonParser.parseJobHistory(result.stdout, profileId: profile.id)
                    try database.saveHistory(history, profileId: profile.id)
                } catch {
                    accountingSucceeded = false
                    if let auditId {
                        try? database.markParseFailure(id: auditId, rawOutput: result.stdout)
                    }
                    reportInternalError("parsing array accounting output", error: error)
                    continue
                }

                let coverage = accountingCoverage(
                    history: history,
                    requestedParentIDs: Set(parentIDBatch)
                )

                for parentID in parentIDBatch {
                    guard let parent = parentByID[parentID],
                          let allTaskIDs = coverage.all[parentID],
                          !allTaskIDs.isEmpty else {
                        continue
                    }
                    let finishedTaskIDs = coverage.finished[parentID] ?? IndexSet()
                    let activeTaskCount = max(0, parent.arrayTasksTotal - parent.arrayTasksDone)
                    let minimumCompleteTotal = parent.arrayTasksTotalIsExact == true
                        ? parent.arrayTasksTotal
                        : activeTaskCount
                    let accountingTotalIsComplete = allTaskIDs.count >= minimumCompleteTotal
                    let selectedTotal = accountingTotalIsComplete
                        ? allTaskIDs.count
                        : parent.arrayTasksTotal
                    let selectedTotalSource = accountingTotalIsComplete
                        ? ArrayProgressTotalSource.accounting
                        : (parent.arrayTasksTotalSource ?? .observedQueue)

                    do {
                        _ = try database.mergeArrayProgress(
                            profileId: profile.id,
                            parentJobID: parentID,
                            total: selectedTotal,
                            finished: finishedTaskIDs.count,
                            totalIsExact: accountingTotalIsComplete || parent.arrayTasksTotalIsExact == true,
                            totalSource: selectedTotalSource,
                            finishedSource: .accounting
                        )

                        // A complete accounting total or an already exact
                        // metadata total means no batch-script lookup is needed.
                        if accountingTotalIsComplete || parent.arrayTasksTotalIsExact == true {
                            accountedParentIDs.insert(parentID)
                            clearArrayFallbackState(parentID: parentID)
                        }
                    } catch {
                        accountingSucceeded = false
                        reportInternalError("saving sacct progress for array \(parentID)", error: error)
                    }
                }
            }

            if accountingDisabled { break }
        }

        let fallbackParents = parents.filter { !accountedParentIDs.contains($0.id) }
        let fallbackSucceeded = await runArrayMetadataFallback(for: fallbackParents)
        return accountingSucceeded && fallbackSucceeded
    }

    @discardableResult
    private func runFairsharePoll() async -> Bool {
        let commandResult = await runLogged(command: commandBuilder.sshareCommand)
        guard case let .success(result, auditId) = commandResult else { return false }

        let score = jsonParser.parseFairshare(result.stdout)
        do {
            try database.saveFairshare(score, profileId: profile.id)
        } catch {
            reportInternalError("saving fairshare", error: error)
            return false
        }

        if score == nil,
           !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isValidJSON(result.stdout),
           let auditId {
            do {
                try database.markParseFailure(id: auditId, rawOutput: result.stdout)
            } catch {
                reportInternalError("marking fairshare parse failure", error: error)
            }
        }

        return true
    }

    @discardableResult
    private func runClusterLoadPoll() async -> Bool {
        let commandResult = await runLogged(command: commandBuilder.clusterLoadCommand)
        guard case let .success(result, auditId) = commandResult else { return false }

        do {
            let inventory = try NodeInventoryParser.parse(output: result.stdout)
            let overview = ClusterOverviewBuilder.build(profileId: profile.id, inventory: inventory)
            do {
                try database.saveClusterOverview(overview)
            } catch {
                reportInternalError("saving cluster overview", error: error)
            }
        } catch {
            // Inventory is auxiliary; continue to load parsing.
        }

        do {
            let load = try jsonParser.parseClusterLoad(result.stdout, profileId: profile.id)
            do {
                try database.saveClusterLoad(load)
                return true
            } catch {
                reportInternalError("saving cluster load", error: error)
                return false
            }
        } catch {
            if let auditId {
                do {
                    try database.markParseFailure(id: auditId, rawOutput: result.stdout)
                } catch {
                    reportInternalError("marking cluster-load parse failure", error: error)
                }
            }
            return false
        }
    }

    private func parseJobsWithFallback(_ output: String) -> (jobs: [JobSnapshot], parseFailed: Bool) {
        do {
            let jobs = try jsonParser.parseJobs(output, profileId: profile.id)
            return (jobs, false)
        } catch {
            return ([], true)
        }
    }

    private func triggerExtendedPollIfNeeded(afterTerminalDiff: Bool = false) {
        if afterTerminalDiff && !shouldRunImmediateExtendedPollAfterTerminalDiff() {
            return
        }

        Task { [weak self] in
            await self?.runExtendedPoll()
        }
    }

    private func shouldRunImmediateExtendedPollAfterTerminalDiff() -> Bool {
        do {
            return try database.isSacctAvailable(profileId: profile.id)
        } catch {
            reportInternalError("reading sacct availability before terminal-triggered extended poll", error: error)
            return true
        }
    }

    private func shouldProbeAccounting(cachedAvailable: Bool) -> Bool {
        if cachedAvailable { return true }

        stateLock.lock()
        defer { stateLock.unlock() }
        let now = Date()
        if let lastProbe = lastUnavailableAccountingProbeAt,
           now.timeIntervalSince(lastProbe) < unavailableAccountingRetryInterval {
            return false
        }
        lastUnavailableAccountingProbeAt = now
        return true
    }

    private func beginEstimatedStartFetch(jobId: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if inFlightEstimatedStartFetches.contains(jobId) {
            return false
        }

        inFlightEstimatedStartFetches.insert(jobId)
        return true
    }

    private func endEstimatedStartFetch(jobId: String) {
        stateLock.lock()
        inFlightEstimatedStartFetches.remove(jobId)
        stateLock.unlock()
    }

    private func beginExtendedPoll() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isExtendedPollInFlight {
            return false
        }

        isExtendedPollInFlight = true
        return true
    }

    private func endExtendedPoll() {
        stateLock.lock()
        isExtendedPollInFlight = false
        stateLock.unlock()
    }

    private func loadLatestLiveOrEmpty() -> [JobSnapshot] {
        do {
            return try database.latestLive(for: profile.id)
        } catch {
            reportInternalError("loading latest live snapshot", error: error)
            return []
        }
    }

    private func loadLastSuccessfulLivePollAt() -> Date? {
        do {
            return try database.lastSuccessfulLivePollAt(profileId: profile.id)
        } catch {
            reportInternalError("loading last successful poll time", error: error)
            return nil
        }
    }

    private func currentArrayParents() -> [JobSnapshot] {
        loadLatestLiveOrEmpty().filter { $0.isArray && $0.arrayTasksTotal > 0 }
    }

    @discardableResult
    private func runArrayMetadataFallback(for parents: [JobSnapshot]) async -> Bool {
        guard !parents.isEmpty else { return true }

        let parentIDs = parents.map(\.id)
        let records: [String: ArrayProgressRecord]
        do {
            records = try database.arrayProgressRecords(
                profileId: profile.id,
                parentJobIDs: parentIDs
            )
        } catch {
            reportInternalError("loading array fallback state", error: error)
            return false
        }

        let eligibleParents = parents.filter { parent in
            if let record = records[parent.id], record.totalIsExact {
                switch record.totalSource {
                case .accounting, .submitLine, .batchScript:
                    return false
                case .observedQueue:
                    break
                }
            }
            return canAttemptArrayFallback(parentID: parent.id)
        }

        var allSucceeded = true
        // Intentionally sequential: this runs outside the live-poll path and
        // limits fallback load on the login node to one request at a time.
        for parent in eligibleParents {
            let activeTaskCount = max(0, parent.arrayTasksTotal - parent.arrayTasksDone)

            if let submittedTotal = parent.arraySubmittedTasksTotal {
                do {
                    _ = try database.mergeArrayProgress(
                        profileId: profile.id,
                        parentJobID: parent.id,
                        total: submittedTotal,
                        finished: max(parent.arrayTasksDone, submittedTotal - activeTaskCount),
                        totalIsExact: true,
                        totalSource: .submitLine,
                        finishedSource: .inferredFromQueue
                    )
                    clearArrayFallbackState(parentID: parent.id)
                } catch {
                    allSucceeded = false
                    recordArrayFallbackFailure(parentID: parent.id)
                    reportInternalError("saving submit-line array size for \(parent.id)", error: error)
                }
                continue
            }

            let command: String
            do {
                command = try commandBuilder.batchScriptCommand(arrayJobId: parent.id)
            } catch {
                allSucceeded = false
                markArrayWithoutScriptMetadata(parentID: parent.id)
                reportInternalError("building batch-script command for \(parent.id)", error: error)
                continue
            }

            switch await runLogged(command: command, maxOutputBytes: maxBatchScriptOutputBytes) {
            case .failure:
                allSucceeded = false
                recordArrayFallbackFailure(parentID: parent.id)

            case .success(let result, _):
                guard let scriptTotal = SlurmArraySpecificationParser.taskCount(inBatchScript: result.stdout) else {
                    allSucceeded = false
                    markArrayWithoutScriptMetadata(parentID: parent.id)
                    continue
                }

                do {
                    _ = try database.mergeArrayProgress(
                        profileId: profile.id,
                        parentJobID: parent.id,
                        total: scriptTotal,
                        finished: max(parent.arrayTasksDone, scriptTotal - activeTaskCount),
                        totalIsExact: true,
                        totalSource: .batchScript,
                        finishedSource: .inferredFromQueue
                    )
                    clearArrayFallbackState(parentID: parent.id)
                } catch {
                    allSucceeded = false
                    recordArrayFallbackFailure(parentID: parent.id)
                    reportInternalError("saving batch-script array size for \(parent.id)", error: error)
                }
            }
        }

        return allSucceeded
    }

    func accountingCoverage(
        history: [JobHistorySnapshot],
        requestedParentIDs: Set<String>
    ) -> ArrayAccountingCoverage {
        var coverage = ArrayAccountingCoverage()

        for entry in history {
            guard let identity = accountingTaskIdentity(
                for: entry,
                requestedParentIDs: requestedParentIDs
            ) else { continue }

            var allTaskIDs = coverage.all[identity.parentID] ?? IndexSet()
            allTaskIDs.formUnion(identity.taskIDs)
            coverage.all[identity.parentID] = allTaskIDs

            if isTerminalArrayTaskState(entry.state) {
                var finishedTaskIDs = coverage.finished[identity.parentID] ?? IndexSet()
                finishedTaskIDs.formUnion(identity.taskIDs)
                coverage.finished[identity.parentID] = finishedTaskIDs
            }
        }

        return coverage
    }

    private func accountingTaskIdentity(
        for entry: JobHistorySnapshot,
        requestedParentIDs: Set<String>
    ) -> (parentID: String, taskIDs: IndexSet)? {
        if let parentID = entry.arrayParentID,
           requestedParentIDs.contains(parentID) {
            if let taskID = entry.arrayTaskID {
                return (parentID, IndexSet(integer: taskID))
            }
            if let expression = entry.arrayTaskExpression,
               let taskIDs = taskIDs(inAccountingExpression: expression) {
                return (parentID, taskIDs)
            }
        }

        if requestedParentIDs.contains(entry.id),
           let expression = entry.arrayTaskExpression,
           let taskIDs = taskIDs(inAccountingExpression: expression) {
            return (entry.id, taskIDs)
        }

        guard let separator = entry.id.firstIndex(of: "_") else { return nil }
        let parentID = String(entry.id[..<separator])
        let taskValue = String(entry.id[entry.id.index(after: separator)...])
        guard requestedParentIDs.contains(parentID),
              let taskIDs = taskIDs(inAccountingExpression: taskValue) else { return nil }
        return (parentID, taskIDs)
    }

    private func taskIDs(inAccountingExpression rawValue: String) -> IndexSet? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "[", value.last == "]" {
            value.removeFirst()
            value.removeLast()
        }
        return SlurmArraySpecificationParser.taskIDs(inSpecification: value)
    }

    private func canAttemptArrayFallback(parentID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !arraysWithoutScriptMetadata.contains(parentID) else { return false }
        return (arrayFallbackRetries[parentID]?.nextAttemptAt ?? .distantPast) <= Date()
    }

    private func recordArrayFallbackFailure(parentID: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let failures = min(8, (arrayFallbackRetries[parentID]?.failures ?? 0) + 1)
        let delay = min(300.0, 15.0 * pow(2.0, Double(failures - 1)))
        arrayFallbackRetries[parentID] = ArrayFallbackRetry(
            failures: failures,
            nextAttemptAt: Date().addingTimeInterval(delay)
        )
    }

    private func markArrayWithoutScriptMetadata(parentID: String) {
        stateLock.lock()
        arraysWithoutScriptMetadata.insert(parentID)
        arrayFallbackRetries[parentID] = nil
        stateLock.unlock()
    }

    private func clearArrayFallbackState(parentID: String) {
        stateLock.lock()
        arraysWithoutScriptMetadata.remove(parentID)
        arrayFallbackRetries[parentID] = nil
        stateLock.unlock()
    }

    private func maxFinishedSource(
        _ lhs: ArrayProgressFinishedSource,
        _ rhs: ArrayProgressFinishedSource
    ) -> ArrayProgressFinishedSource {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }

    private func isTerminalArrayTaskState(_ state: JobState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .timeout, .outOfMemory:
            return true
        case .pending, .running, .completing, .unknown:
            return false
        }
    }

    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            return false
        }
    }

    private func isAccountingStorageDisabled(_ text: String) -> Bool {
        SlurmErrorClassifier.isAccountingStorageDisabled(text)
    }

    private enum LoggedResult {
        case success(CommandResult, Int64?)
        case failure(Error)
    }

    private func runLogged(
        command: String,
        maxOutputBytes: Int? = nil
    ) async -> LoggedResult {
        let execution = await AuditedCommandRunner.run(
            profile: profile,
            command: command,
            database: database,
            execute: {
                try await self.connection.run(command, maxOutputBytes: maxOutputBytes)
            },
            reportInternalError: { context, error in
                self.reportInternalError(context, error: error)
            }
        )

        switch execution.result {
        case .success(let result):
            return .success(result, execution.auditId)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func reportInternalError(_ context: String, error: Error) {
        OrbitDiagnostics.report(
            component: "PollEngine",
            context: "[\(profile.displayName)] \(context)",
            error: error
        )
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maxCount).map { start in
            Array(self[start..<Swift.min(start + maxCount, count)])
        }
    }
}
