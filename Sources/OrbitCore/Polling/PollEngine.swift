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

    private let stateLock = NSLock()
    private var inFlightEstimatedStartFetches: Set<String> = []
    private var isExtendedPollInFlight = false

    private let maxEstimatedStartFetchesPerPoll = 5

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

            let jobs = parse.jobs
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

    public func runExtendedPoll() async {
        guard beginExtendedPoll() else { return }
        defer { endExtendedPoll() }

        let sacctAvailable: Bool
        do {
            sacctAvailable = try database.isSacctAvailable(profileId: profile.id)
        } catch {
            reportInternalError("reading sacct capability", error: error)
            sacctAvailable = true
        }

        if sacctAvailable {
            _ = await runSacctPoll()
        }

        if profile.fairshareEnabled {
            _ = await runFairsharePoll()
        }

        _ = await runClusterLoadPoll()
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

    private func runLogged(command: String) async -> LoggedResult {
        let execution = await AuditedCommandRunner.run(
            profile: profile,
            command: command,
            database: database,
            execute: {
                try await self.connection.run(command)
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
