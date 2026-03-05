import Foundation
import OrbitCore

@main
struct OrbitCLI {
    static func main() async {
        var service: OrbitService?
        var exitCode: Int32 = 0

        do {
            let env = ProcessInfo.processInfo.environment
            let dbPath = env["ORBIT_DB_PATH"] ?? OrbitDatabase.defaultPath()
            let database = try OrbitDatabase(
                path: dbPath,
                auditRetentionDays: OrbitEnvironment.int(env, key: "ORBIT_AUDIT_RETENTION_DAYS") ?? 8,
                historyRetentionDays: OrbitEnvironment.int(env, key: "ORBIT_HISTORY_RETENTION_DAYS") ?? 8,
                notificationRetentionDays: OrbitEnvironment.int(env, key: "ORBIT_NOTIFICATION_RETENTION_DAYS") ?? 8,
                maxHistoryEntriesPerPoll: OrbitEnvironment.int(env, key: "ORBIT_MAX_HISTORY_ENTRIES_PER_POLL") ?? 2_000,
                maxDatabaseSizeMB: OrbitEnvironment.int(env, key: "ORBIT_MAX_DB_SIZE_MB") ?? 200
            )

            let notificationsEnabled = env["ORBIT_ENABLE_NOTIFICATIONS"] != "0"
            let notificationEngine: NotificationEngine
            if notificationsEnabled {
                _ = await UserNotificationEngine.requestAuthorization()
                notificationEngine = UserNotificationEngine(database: database)
            } else {
                notificationEngine = NoopNotificationEngine()
            }

            let createdService = OrbitService(database: database, notificationEngine: notificationEngine)
            service = createdService

            let args = Array(CommandLine.arguments.dropFirst())
            if let first = args.first {
                switch first {
                case "profile":
                    try await handleProfile(Array(args.dropFirst()), service: createdService)
                case "test":
                    try await handleTest(Array(args.dropFirst()), service: createdService)
                case "poll":
                    try await handlePoll(Array(args.dropFirst()), service: createdService)
                case "watch":
                    try await handleWatch(Array(args.dropFirst()), service: createdService)
                case "nodes":
                    try await handleNodes(Array(args.dropFirst()), service: createdService)
                case "status":
                    try await handleStatus(Array(args.dropFirst()), service: createdService)
                case "audit":
                    try await handleAudit(Array(args.dropFirst()), database: database)
                case "storage":
                    try handleStorage(Array(args.dropFirst()), database: database)
                default:
                    printUsage()
                }
            } else {
                printUsage()
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exitCode = 1
        }

        if let service {
            await service.shutdown()
        }

        if exitCode != 0 {
            exit(exitCode)
        }
    }

    private static func handleProfile(_ args: [String], service: OrbitService) async throws {
        guard let sub = args.first else {
            printProfileUsage()
            return
        }

        switch sub {
        case "add":
            let opts = parseOptions(Array(args.dropFirst()))
            let name = opts["--name"] ?? prompt("Display name")
            let host = opts["--host"] ?? prompt("Hostname")
            let user = opts["--user"] ?? prompt("Username")
            let port = Int(opts["--port"] ?? "22") ?? 22
            var keyPath = opts["--key"]
            var useSSHConfig = opts["--no-ssh-config"] == nil

            guard !name.isEmpty, !host.isEmpty, !user.isEmpty else {
                throw CLIError.invalidArguments("Missing required profile fields")
            }

            if opts["--auto-detect-auth"] == "true" {
                let detection = await service.detectAuth(hostname: host, username: user)
                if let config = detection.configMatch {
                    useSSHConfig = true
                    if keyPath == nil, let identity = config.identityFile {
                        keyPath = identity
                    }
                    print("Auth detection: found ~/.ssh/config host \(config.hostPattern)")
                } else if keyPath == nil, let recommended = detection.recommendedKey {
                    keyPath = recommended
                    useSSHConfig = false
                    print("Auth detection: using recommended key \(recommended)")
                } else {
                    print("Auth detection: no usable ssh config/key found")
                }
            }

            let profile = ClusterProfile(
                displayName: name,
                hostname: host,
                port: port,
                username: user,
                sshKeyPath: keyPath,
                useSSHConfig: useSSHConfig
            )
            try service.addProfile(profile)
            print("Added profile \(profile.displayName) (\(profile.id.uuidString))")

            let shouldRunInitialTest = opts["--no-test"] != "true"
            if shouldRunInitialTest {
                do {
                    let result = try await service.testConnection(identifier: profile.id.uuidString)
                    print("Initial test: connected, mode=\(result.outputMode.rawValue), jobs=\(result.jobCount), sacct=\(result.sacctAvailable ? "on" : "off")")
                } catch {
                    fputs("Warning: initial test failed: \(error.localizedDescription)\n", stderr)
                }
            }

        case "list":
            let profiles = try service.listProfiles()
            if profiles.isEmpty {
                print("No profiles configured yet.")
                return
            }

            for profile in profiles {
                let active = profile.isActive ? "active" : "inactive"
                print("- \(profile.displayName) [\(profile.id.uuidString)] \(profile.username)@\(profile.hostname):\(profile.port) mode=\(profile.outputMode.rawValue) \(active)")
            }

        case "enable":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: orbit profile enable <profile-name-or-id>")
            }
            try service.setProfileActive(identifier: args[1], isActive: true)
            print("Profile enabled: \(args[1])")

        case "disable":
            guard args.count >= 2 else {
                throw CLIError.invalidArguments("Usage: orbit profile disable <profile-name-or-id>")
            }
            try service.setProfileActive(identifier: args[1], isActive: false)
            print("Profile disabled: \(args[1])")

        case "detect-auth":
            let opts = parseOptions(Array(args.dropFirst()))
            let host = opts["--host"] ?? prompt("Hostname")
            let user = opts["--user"] ?? prompt("Username")
            guard !host.isEmpty, !user.isEmpty else {
                throw CLIError.invalidArguments("Usage: orbit profile detect-auth --host HOST --user USER")
            }

            let detection = await service.detectAuth(hostname: host, username: user)
            if let config = detection.configMatch {
                print("Found ssh config host: \(config.hostPattern)")
                if let identity = config.identityFile { print("IdentityFile: \(identity)") }
                if let configUser = config.user { print("User: \(configUser)") }
                if let configPort = config.port { print("Port: \(configPort)") }
                if let proxy = config.proxyJump { print("ProxyJump: \(proxy)") }
            } else if !detection.workingKeys.isEmpty {
                print("Working keys:")
                for key in detection.workingKeys { print("- \(key)") }
            } else {
                print("No usable ssh config/key found.")
            }

        default:
            printProfileUsage()
        }
    }

    private static func handleTest(_ args: [String], service: OrbitService) async throws {
        guard let id = args.first else {
            throw CLIError.invalidArguments("Usage: orbit test <profile-name-or-id>")
        }

        let result = try await service.testConnection(identifier: id)
        print("Connected: \(result.profile.displayName)")
        print("SLURM: \(result.slurmVersionRaw)")
        print("Output mode: \(result.outputMode.rawValue)")
        print("Jobs found: \(result.jobCount)")
        if !result.partitions.isEmpty {
            print("Partitions: \(result.partitions.joined(separator: ", "))")
        }
        print("tmux: \(result.tmuxAvailable ? "available" : "not found")")
        print("sacct history: \(result.sacctAvailable ? "available" : "disabled on cluster")")

    }

    private static func handlePoll(_ args: [String], service: OrbitService) async throws {
        guard let id = args.first else {
            throw CLIError.invalidArguments("Usage: orbit poll <profile-name-or-id>")
        }

        let result = try await service.pollOnce(identifier: id)

        if let error = result.error {
            if let age = result.staleAgeSeconds {
                fputs("Warning: \(error) (showing stale cached data, age=\(formatAge(age)))\n", stderr)
            } else {
                let stale = result.usedStaleData ? " (showing stale cached data)" : ""
                fputs("Warning: \(error)\(stale)\n", stderr)
            }
        }

        if let last = result.lastSuccessfulPollAt {
            print("Last successful poll: \(ISO8601DateFormatter().string(from: last))")
        }

        if result.jobs.isEmpty {
            print("No active jobs.")
            return
        }

        for job in result.jobs {
            let used = formatDuration(job.timeUsed)
            let limit = job.timeLimit.map { formatDuration($0) } ?? "unlimited"
            print("\(job.id) \(job.state.rawValue) \(job.name) \(used)/\(limit)")
            if job.isArray && job.arrayTasksTotal > 0 {
                print("  array: done=\(job.arrayTasksDone)/\(job.arrayTasksTotal)")
            }
        }
    }

    private static func handleWatch(_ args: [String], service: OrbitService) async throws {
        service.startLifecycleMonitoring()

        let opts = parseOptions(args)
        let iterations = opts["--iterations"].flatMap(Int.init)

        if opts["--all"] == "true" {
            print("Watching all active profiles... press Ctrl+C to stop")
            try await service.watchAll(iterations: iterations) { tick in
                let timestamp = ISO8601DateFormatter().string(from: Date())
                if let error = tick.result.error {
                    let agePart = tick.result.staleAgeSeconds.map { " stale_age=\(formatAge($0))" } ?? ""
                    let stale = tick.result.usedStaleData ? " stale=true" : ""
                    fputs("[\(timestamp)] profile=\(tick.profile.displayName) tick=\(tick.tick) error=\(error)\(stale)\(agePart)\n", stderr)
                } else {
                    print("[\(timestamp)] profile=\(tick.profile.displayName) tick=\(tick.tick) jobs=\(tick.result.jobs.count)")
                }
            }
            print("Watch ended.")
            return
        }

        guard let id = args.first(where: { !$0.hasPrefix("--") }) else {
            throw CLIError.invalidArguments("Usage: orbit watch <profile-name-or-id> [--iterations N] | orbit watch --all [--iterations N]")
        }

        print("Watching \(id)... press Ctrl+C to stop")
        try await service.watch(identifier: id, iterations: iterations) { result, tick in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            if let error = result.error {
                let agePart = result.staleAgeSeconds.map { " stale_age=\(formatAge($0))" } ?? ""
                let stale = result.usedStaleData ? " stale=true" : ""
                fputs("[\(timestamp)] tick=\(tick) error=\(error)\(stale)\(agePart)\n", stderr)
            } else {
                print("[\(timestamp)] tick=\(tick) jobs=\(result.jobs.count)")
            }
        }
        print("Watch ended.")
    }

    private static func handleNodes(_ args: [String], service: OrbitService) async throws {
        guard let id = args.first else {
            throw CLIError.invalidArguments("Usage: orbit nodes <profile-name-or-id>")
        }

        let result = try await service.nodeInventory(identifier: id)
        print("Nodes: \(result.nodes.count)")

        for node in result.nodes {
            let mem = node.memoryMB.map { "\(Int(Double($0) / 1024.0))GB" } ?? "-"
            let parts = node.partitions.isEmpty ? "-" : node.partitions.joined(separator: ",")
            print("- \(node.name) state=\(node.state) cpu=\(node.allocatedCPUs)/\(node.totalCPUs) mem=\(mem) part=\(parts)")
        }

        if !result.partitions.isEmpty {
            print("\nPartition configs:")
            for part in result.partitions {
                let memPerCPU = part.defaultMemoryPerCPUMB.map { "\($0)MB/cpu" } ?? "-"
                let defTime = part.defaultTimeMinutes.map(String.init) ?? "-"
                let maxTime = part.maxTimeMinutes.map(String.init) ?? "-"
                let nodes = part.configuredNodes ?? "-"
                let cpus = part.totalCPUs.map(String.init) ?? "-"
                print("- \(part.name) state=\(part.state ?? "-") nodes=\(nodes) cpus=\(cpus) mem=\(memPerCPU) default_time=\(defTime)m max_time=\(maxTime)m")
            }
        }
    }

    private static func handleStatus(_ args: [String], service: OrbitService) async throws {
        let opts = parseOptions(args)
        let refresh = opts["--refresh"] == "true"

        if opts["--all"] == "true" {
            let activeOnly = opts["--active-only"] == "true"
            let statuses = try await service.statusAll(refresh: refresh, activeOnly: activeOnly)
            if statuses.isEmpty {
                print("No profiles found.")
                return
            }

            for status in statuses {
                print(statusLine(status))
            }
            return
        }

        guard let id = args.first(where: { !$0.hasPrefix("--") }) else {
            throw CLIError.invalidArguments("Usage: orbit status <profile> [--refresh] | orbit status --all [--active-only] [--refresh]")
        }

        let status = try await service.status(identifier: id, refresh: refresh)
        printStatusDetails(status)
    }

    private static func handleAudit(_ args: [String], database: OrbitDatabase) async throws {
        let opts = parseOptions(args)
        let limit = opts["--last"].flatMap(Int.init) ?? 50

        let rows = try database.recentAudit(limit: max(1, limit))
        if rows.isEmpty {
            print("No audit entries yet.")
            return
        }

        for row in rows {
            let status = row.exit_code == nil ? "pending" : (row.exit_code == 0 ? "ok" : "error")
            let duration = row.duration_ms.map { "\($0)ms" } ?? "-"
            print("\(row.timestamp) \(row.cluster_name) \(status) \(duration)")
            print("  \(row.command)")
            if let error = row.error, !error.isEmpty {
                print("  stderr: \(error)")
            }
            if row.parse_failed == 1 {
                print("  parse_failed: true")
            }
        }
    }

    private static func handleStorage(_ args: [String], database: OrbitDatabase) throws {
        guard let sub = args.first else {
            printStorageUsage()
            return
        }

        switch sub {
        case "stats":
            let stats = try database.storageStats()
            print("Database file: \(formatBytes(stats.fileSizeBytes))")
            print("retention_days: audit=\(stats.auditRetentionDays), history=\(stats.historyRetentionDays), notifications=\(stats.notificationRetentionDays)")
            print("limits: max_history_entries_per_poll=\(stats.maxHistoryEntriesPerPoll), max_database_size=\(formatBytes(stats.maxDatabaseSizeBytes))")
            print("profiles=\(stats.profileCount)")
            print("live_poll_batches=\(stats.livePollBatchCount)")
            print("job_snapshots=\(stats.jobSnapshotCount)")
            print("job_history=\(stats.jobHistoryCount)")
            print("audit_log=\(stats.auditLogCount)")
            print("notification_state=\(stats.notificationStateCount)")

        case "vacuum":
            try database.vacuum()
            let stats = try database.storageStats()
            print("Vacuum completed. Database file: \(formatBytes(stats.fileSizeBytes))")

        default:
            printStorageUsage()
        }
    }

}

enum CLIError: Error, LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        }
    }
}
