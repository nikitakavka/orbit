import Foundation

public struct ProfileTestResult {
    public let profile: ClusterProfile
    public let slurmVersionRaw: String
    public let slurmVersion: SlurmVersion?
    public let outputMode: SlurmOutputMode
    public let jobCount: Int
    public let partitions: [String]
    public let tmuxAvailable: Bool
    public let sacctAvailable: Bool
}

public struct ProfileWatchTick {
    public let profile: ClusterProfile
    public let result: LivePollResult
    public let tick: Int
}

public enum OrbitServiceError: Error, LocalizedError {
    case noActiveProfiles
    case invalidProfile(String)
    case legacySlurmUnsupported

    public var errorDescription: String? {
        switch self {
        case .noActiveProfiles:
            return "No active cluster profiles found. Enable a profile first."
        case .invalidProfile(let message):
            return message
        case .legacySlurmUnsupported:
            return "Legacy SLURM is not supported in this build. Orbit requires SLURM JSON output support (21.08+)."
        }
    }
}

public final class OrbitService {
    public let database: OrbitDatabase
    let pool: SSHConnectionPool
    let notificationEngine: NotificationEngine
    let lifecycleMonitor: ConnectionLifecycleMonitor

    public init(
        database: OrbitDatabase,
        pool: SSHConnectionPool = SSHConnectionPool(),
        notificationEngine: NotificationEngine = NoopNotificationEngine()
    ) {
        self.database = database
        self.pool = pool
        self.notificationEngine = notificationEngine
        self.lifecycleMonitor = ConnectionLifecycleMonitor(pool: pool)
    }

    public func addProfile(_ profile: ClusterProfile) throws {
        let displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = profile.hostname.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !displayName.isEmpty else {
            throw OrbitServiceError.invalidProfile("Display name cannot be empty.")
        }

        guard !hostname.isEmpty else {
            throw OrbitServiceError.invalidProfile("Hostname cannot be empty.")
        }

        guard Self.isLikelyValidHostname(hostname) else {
            throw OrbitServiceError.invalidProfile("Hostname contains unsupported characters.")
        }

        guard (1...65535).contains(profile.port) else {
            throw OrbitServiceError.invalidProfile("Port must be in range 1...65535.")
        }

        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SlurmCommandBuilder.isValidUsername(username) else {
            throw OrbitServiceError.invalidProfile("Username contains unsupported characters. Allowed: letters, digits, dot, underscore, dash.")
        }

        if let grafanaURL = profile.grafanaURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !grafanaURL.isEmpty,
           !Self.isValidGrafanaURL(grafanaURL) {
            throw OrbitServiceError.invalidProfile("Grafana URL must be a valid http/https URL.")
        }

        let existingProfiles = try database.listProfiles()
        let hasDuplicateName = existingProfiles.contains { existing in
            existing.id != profile.id && existing.displayName.compare(displayName, options: .caseInsensitive) == .orderedSame
        }
        if hasDuplicateName {
            throw OrbitServiceError.invalidProfile("Profile display name must be unique.")
        }

        var normalized = profile
        normalized.displayName = displayName
        normalized.hostname = hostname
        normalized.username = username
        normalized.grafanaURL = normalized.grafanaURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.grafanaURL?.isEmpty == true {
            normalized.grafanaURL = nil
        }

        try database.saveProfile(normalized)
    }

    public func deleteProfile(id: UUID) throws {
        try database.deleteProfile(id: id)
        Task { [pool] in
            await pool.removeConnection(for: id)
        }
    }

    public func listProfiles() throws -> [ClusterProfile] {
        try database.listProfiles()
    }

    public func recentAudit(limit: Int = 100) throws -> [AuditLogEntry] {
        try database.recentAudit(limit: max(1, limit))
    }

    public func historyEntry(profileId: UUID, jobId: String) throws -> JobHistorySnapshot? {
        try database.latestHistoryEntry(profileId: profileId, jobId: jobId)
    }

    public func profile(identifier: String) throws -> ClusterProfile {
        try database.loadProfile(identifier)
    }

    public func setProfileActive(identifier: String, isActive: Bool) throws {
        var profile = try database.loadProfile(identifier)
        profile.isActive = isActive
        try database.saveProfile(profile)
    }

    public func detectAuth(hostname: String, username: String) async -> SSHDetectionResult {
        await SSHKeyDetector.detectSSHConfig(hostname: hostname, username: username)
    }

    public func testConnection(identifier: String) async throws -> ProfileTestResult {
        var profile = try database.loadProfile(identifier)
        let connection = await pool.connection(for: profile)

        let versionResult = try await runAuditedCommand(
            profile: profile,
            connection: connection,
            command: SlurmCommandBuilder.slurmVersionCommand
        )

        let slurmVersionRaw = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedVersion = SlurmVersion(parsing: slurmVersionRaw)

        let mode: SlurmOutputMode
        if let parsedVersion {
            guard parsedVersion.supportsJSON else {
                throw OrbitServiceError.legacySlurmUnsupported
            }
            mode = .json
        } else {
            mode = .unknown
        }

        profile.outputMode = mode
        profile.slurmVersion = parsedVersion.map { "\($0.major).\($0.minor).\($0.patch)" } ?? slurmVersionRaw
        try database.saveProfile(profile)

        let builder = try SlurmCommandBuilder(mode: mode, username: profile.username)

        let queueResult = try await runAuditedCommand(
            profile: profile,
            connection: connection,
            command: builder.squeueCommand
        )

        let parser = JSONSlurmParser()
        let jobs: [JobSnapshot]
        do {
            jobs = try parser.parseJobs(queueResult.stdout, profileId: profile.id)
        } catch {
            reportInternalError("parsing test-connection queue output", error: error)
            jobs = []
        }

        let partitions: [String]
        do {
            let partitionsResult = try await runAuditedCommand(
                profile: profile,
                connection: connection,
                command: SlurmCommandBuilder.partitionsCommand
            )
            partitions = parsePartitions(partitionsResult.stdout)
        } catch {
            reportInternalError("reading partition list during connection test", error: error)
            partitions = []
        }

        let tmuxAvailable: Bool
        do {
            let tmuxResult = try await runAuditedCommand(
                profile: profile,
                connection: connection,
                command: SlurmCommandBuilder.tmuxCheckCommand
            )
            tmuxAvailable = (tmuxResult.exitCode == 0)
        } catch {
            tmuxAvailable = false
        }

        let sacctAvailable: Bool
        do {
            _ = try await runAuditedCommand(
                profile: profile,
                connection: connection,
                command: builder.sacctCommand
            )
            sacctAvailable = true
            do {
                try database.setSacctAvailability(profileId: profile.id, available: true)
            } catch {
                reportInternalError("updating sacct availability=true during connection test", error: error)
            }
        } catch {
            if isAccountingStorageDisabled(error.localizedDescription) {
                sacctAvailable = false
                do {
                    try database.setSacctAvailability(
                        profileId: profile.id,
                        available: false,
                        note: "Slurm accounting storage is disabled"
                    )
                } catch {
                    reportInternalError("updating sacct availability=false during connection test", error: error)
                }
            } else {
                sacctAvailable = true
            }
        }

        return ProfileTestResult(
            profile: profile,
            slurmVersionRaw: slurmVersionRaw,
            slurmVersion: parsedVersion,
            outputMode: mode,
            jobCount: jobs.count,
            partitions: partitions,
            tmuxAvailable: tmuxAvailable,
            sacctAvailable: sacctAvailable
        )
    }

    public func pollOnce(identifier: String) async throws -> LivePollResult {
        let profile = try database.loadProfile(identifier)
        try validateProfileSupportsJSON(profile)
        let connection = await pool.connection(for: profile)
        let engine = try PollEngine(
            profile: profile,
            connection: connection,
            database: database,
            notificationEngine: notificationEngine
        )
        return await engine.runLivePoll()
    }

    public func nodeInventory(identifier: String) async throws -> NodeInventoryResult {
        let profile = try database.loadProfile(identifier)
        try validateProfileSupportsJSON(profile)
        let connection = await pool.connection(for: profile)
        let builder = try SlurmCommandBuilder(mode: profile.outputMode, username: profile.username)

        let result = try await runAuditedCommand(
            profile: profile,
            connection: connection,
            command: builder.clusterLoadCommand
        )

        return try NodeInventoryParser.parse(output: result.stdout)
    }

    public func status(identifier: String, refresh: Bool = false) async throws -> ProfileStatus {
        let profile = try database.loadProfile(identifier)
        if refresh {
            _ = try await pollOnce(identifier: identifier)
        }
        return try buildStatus(for: profile)
    }

    public func statusAll(refresh: Bool = false, activeOnly: Bool = false) async throws -> [ProfileStatus] {
        var profiles = try database.listProfiles()
        if activeOnly {
            profiles = profiles.filter { $0.isActive }
        }

        if refresh {
            for profile in profiles {
                do {
                    _ = try await pollOnce(identifier: profile.id.uuidString)
                } catch {
                    // Isolate per-profile refresh failures so one broken profile
                    // does not hide status for all other profiles.
                    reportInternalError("refreshing status for profile \(profile.displayName)", error: error)
                }
            }
        }

        return try profiles.map { try buildStatus(for: $0) }
    }

    public func cpuCoreHistory(profileId: UUID, lastHours: Int = 6) throws -> [CPUCoreDataPoint] {
        let hours = max(1, lastHours)
        let since = Date().addingTimeInterval(TimeInterval(-hours * 60 * 60))
        return try database.cpuCoreHistory(profileId: profileId, since: since)
    }

    func buildStatus(for profile: ClusterProfile) throws -> ProfileStatus {
        let liveJobs = try database.latestLive(for: profile.id)
        let lastPoll = try database.lastSuccessfulLivePollAt(profileId: profile.id)
        let fairshare = try database.latestFairshare(profileId: profile.id)
        let clusterLoad = try database.latestClusterLoad(profileId: profile.id)
        let clusterOverview = try database.latestClusterOverview(profileId: profile.id)
        let sacct = try database.sacctCapability(profileId: profile.id)

        return ProfileStatus(
            profile: profile,
            liveJobs: liveJobs,
            lastSuccessfulPollAt: lastPoll,
            sacctAvailable: sacct.available,
            sacctNote: sacct.note,
            fairshareScore: fairshare,
            clusterLoad: clusterLoad,
            clusterOverview: clusterOverview
        )
    }

    private static func isLikelyValidHostname(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace }) else { return false }
        guard !value.contains("@"), !value.contains("/") else { return false }
        return value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    }

    private static func isValidGrafanaURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return false
        }

        return true
    }
}
