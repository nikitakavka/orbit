import Foundation
import Testing
@preconcurrency import GRDB
@testable import OrbitCore

struct OrbitCoreDatabaseTests {
    @Test
    func databaseRejectsAmbiguousProfileNamesOnLookup() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)

        try db.saveProfile(ClusterProfile(displayName: "dup", hostname: "hpc-a", username: "alice"))
        try db.saveProfile(ClusterProfile(displayName: "dup", hostname: "hpc-b", username: "alice"))

        var rejected = false
        do {
            _ = try db.loadProfile("dup")
        } catch OrbitDatabaseError.ambiguousProfileName {
            rejected = true
        }

        #expect(rejected)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseStorageStatsExposeConfiguredPolicy() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(
            path: path,
            auditRetentionDays: 12,
            historyRetentionDays: 10,
            notificationRetentionDays: 8,
            maxHistoryEntriesPerPoll: 777,
            maxDatabaseSizeMB: 120
        )

        let stats = try db.storageStats()
        #expect(stats.auditRetentionDays == 8)
        #expect(stats.historyRetentionDays == 8)
        #expect(stats.notificationRetentionDays == 8)
        #expect(stats.maxHistoryEntriesPerPoll == 777)
        #expect(stats.maxDatabaseSizeBytes == Int64(120 * 1024 * 1024))

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databasePrunesAuditLogByRetention() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path, auditRetentionDays: 1)
        let profile = ClusterProfile(displayName: "test", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldTimestamp = formatter.string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60))

        try db.dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO audit_log (timestamp, profile_id, cluster_name, command, exit_code, duration_ms, error, parse_failed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [oldTimestamp, profile.id.uuidString, "old-cluster", "sinfo --version", 0, 5, nil, 0]
            )
        }

        _ = try db.recordAuditStart(profile: profile, command: "sinfo --version")

        let logs = try db.recentAudit(limit: 20)
        #expect(!logs.contains(where: { $0.cluster_name == "old-cluster" }))

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseHistoryUpsertsByProfileAndJob() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let profile = ClusterProfile(displayName: "hist", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let first = JobHistorySnapshot(
            id: "123",
            profileId: profile.id,
            name: "job",
            state: .running,
            exitCode: nil,
            elapsed: 60,
            timeLimit: 3600,
            cpuTimeUsed: 120,
            cpusRequested: 2,
            maxRSS: nil,
            memoryRequested: nil,
            startTime: Date().addingTimeInterval(-120),
            endTime: nil
        )

        let second = JobHistorySnapshot(
            id: "123",
            profileId: profile.id,
            name: "job",
            state: .completed,
            exitCode: "0:0",
            elapsed: 180,
            timeLimit: 3600,
            cpuTimeUsed: 300,
            cpusRequested: 2,
            maxRSS: nil,
            memoryRequested: nil,
            startTime: Date().addingTimeInterval(-240),
            endTime: Date()
        )

        try db.saveHistory([first], profileId: profile.id)
        try db.saveHistory([second], profileId: profile.id)

        let latest = try db.latestHistoryEntry(profileId: profile.id, jobId: "123")
        #expect(latest?.state == .completed)

        let count = try db.dbQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM job_history WHERE profile_id = ? AND job_id = ?",
                arguments: [profile.id.uuidString, "123"]
            ) ?? 0
        }
        #expect(count == 1)

        let storedElapsed: TimeInterval? = try db.dbQueue.read { database in
            let data = try String.fetchOne(
                database,
                sql: "SELECT data FROM job_history WHERE profile_id = ? AND job_id = ?",
                arguments: [profile.id.uuidString, "123"]
            )
            guard let data, let raw = data.data(using: .utf8) else { return nil }
            let snapshot = try JSONDecoder().decode(JobHistorySnapshot.self, from: raw)
            return snapshot.elapsed
        }
        #expect(storedElapsed == 180)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databasePrunesNotificationStateByRetention() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path, notificationRetentionDays: 1)
        let profile = ClusterProfile(displayName: "notify", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldTimestamp = formatter.string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60))

        try db.dbQueue.write { database in
            try database.execute(
                sql: "INSERT INTO notification_state (job_id, profile_id, event_type, fired_at) VALUES (?, ?, ?, ?)",
                arguments: ["old-job", profile.id.uuidString, "completed", oldTimestamp]
            )
        }

        try db.markNotificationFired(jobId: "new-job", profileId: profile.id, eventType: "completed")

        let oldCount = try db.dbQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM notification_state WHERE job_id = ?",
                arguments: ["old-job"]
            ) ?? 0
        }
        #expect(oldCount == 0)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseReportsWhetherJobWasSeenRunning() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let profile = ClusterProfile(displayName: "seen-running", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let pendingOnly = JobSnapshot(
            id: "1000",
            profileId: profile.id,
            name: "pending-only",
            state: .pending,
            partition: "main",
            nodes: 1,
            cpus: 1,
            timeUsed: 0,
            timeLimit: 300,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        let running = JobSnapshot(
            id: "2000",
            profileId: profile.id,
            name: "ran-once",
            state: .running,
            partition: "main",
            nodes: 1,
            cpus: 1,
            timeUsed: 15,
            timeLimit: 300,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        try db.saveLive([pendingOnly], profileId: profile.id)
        try db.saveLive([running], profileId: profile.id)
        try db.saveLive([], profileId: profile.id)

        #expect((try db.jobWasSeenRunning(profileId: profile.id, jobId: "1000")) == false)
        #expect((try db.jobWasSeenRunning(profileId: profile.id, jobId: "2000")) == true)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseReportsWhetherArrayWasSeenRunning() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let profile = ClusterProfile(displayName: "array-seen-running", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let pendingChild = JobSnapshot(
            id: "3001",
            profileId: profile.id,
            name: "array-pending",
            state: .pending,
            partition: "main",
            nodes: 1,
            cpus: 1,
            timeUsed: 0,
            timeLimit: 300,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayParentID: "3000",
            arrayTaskID: 1,
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        let runningChild = JobSnapshot(
            id: "4000_1",
            profileId: profile.id,
            name: "array-ran",
            state: .running,
            partition: "main",
            nodes: 1,
            cpus: 1,
            timeUsed: 10,
            timeLimit: 300,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayParentID: "4000",
            arrayTaskID: 1,
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        try db.saveLive([pendingChild], profileId: profile.id)
        try db.saveLive([runningChild], profileId: profile.id)
        try db.saveLive([], profileId: profile.id)

        #expect((try db.arrayWasSeenRunning(profileId: profile.id, arrayRootId: "3000")) == false)
        #expect((try db.arrayWasSeenRunning(profileId: profile.id, arrayRootId: "4000")) == true)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseRoundTripProfileAndAudit() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let profile = ClusterProfile(displayName: "test", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let loaded = try db.loadProfile("test")
        #expect(loaded.id == profile.id)

        let auditId = try db.recordAuditStart(profile: profile, command: "squeue --user=alice --json")
        let result = CommandResult(command: "squeue --user=alice --json", stdout: "{}", stderr: "", exitCode: 0, timestamp: Date(), durationMs: 10)
        try db.recordAuditFinish(id: auditId, result: result, error: nil)
        try db.markParseFailure(id: auditId, rawOutput: "bad json")

        let logs = try db.recentAudit(limit: 1)
        #expect(logs.count == 1)
        #expect(logs.first?.exit_code == 0)
        #expect(logs.first?.parse_failed == 1)

        let sampleJob = JobSnapshot(
            id: "1",
            profileId: profile.id,
            name: "job",
            state: .running,
            partition: "gpu",
            nodes: 1,
            cpus: 4,
            timeUsed: 60,
            timeLimit: 3600,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        try db.saveLive([sampleJob], profileId: profile.id)
        let firstLive = try db.latestLive(for: profile.id)
        #expect(firstLive.count == 1)

        try db.saveLive([], profileId: profile.id)
        let secondLive = try db.latestLive(for: profile.id)
        #expect(secondLive.isEmpty)
        #expect(try db.lastSuccessfulLivePollAt(profileId: profile.id) != nil)

        #expect(try db.isSacctAvailable(profileId: profile.id) == true)
        try db.setSacctAvailability(profileId: profile.id, available: false, note: "disabled")
        #expect(try db.isSacctAvailable(profileId: profile.id) == false)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseReturnsCPUCoreHistory() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let profile = ClusterProfile(displayName: "cpu", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let first = JobSnapshot(
            id: "100",
            profileId: profile.id,
            name: "run-a",
            state: .running,
            partition: "gpu",
            nodes: 1,
            cpus: 4,
            timeUsed: 60,
            timeLimit: 600,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        try db.saveLive([first], profileId: profile.id)

        let second = JobSnapshot(
            id: "101",
            profileId: profile.id,
            name: "run-b",
            state: .running,
            partition: "gpu",
            nodes: 1,
            cpus: 12,
            timeUsed: 30,
            timeLimit: 600,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        try db.saveLive([second], profileId: profile.id)

        let points = try db.cpuCoreHistory(profileId: profile.id, since: Date().addingTimeInterval(-60 * 60))
        #expect(points.count >= 2)
        #expect(points.last?.totalCoresInUse == 12)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseRetainsFullResolutionWithin8DaysAndPrunesOlderSamples() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let profile = ClusterProfile(displayName: "retention", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let now = Date()
        let oldBeyondRetention = now.addingTimeInterval(-9 * 24 * 60 * 60)
        let withinRetentionA = now.addingTimeInterval(-6 * 60 * 60)
        let withinRetentionB = now.addingTimeInterval(-6 * 60 * 60 + 120)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let oldISO = formatter.string(from: oldBeyondRetention)
        let keepAISO = formatter.string(from: withinRetentionA)
        let keepBISO = formatter.string(from: withinRetentionB)

        try db.dbQueue.write { database in
            for (idx, ts) in [oldISO, keepAISO, keepBISO].enumerated() {
                try database.execute(
                    sql: "INSERT INTO live_poll_batches (profile_id, snapshot_time) VALUES (?, ?)",
                    arguments: [profile.id.uuidString, ts]
                )

                try database.execute(
                    sql: "INSERT INTO job_snapshots (profile_id, job_id, data, snapshot_time) VALUES (?, ?, ?, ?)",
                    arguments: [profile.id.uuidString, "legacy-\(idx)", "{}", ts]
                )

                try database.execute(
                    sql: "INSERT INTO cpu_core_history (profile_id, timestamp, cores_in_use) VALUES (?, ?, ?)",
                    arguments: [profile.id.uuidString, ts, idx + 1]
                )
            }
        }

        try db.saveLive([], profileId: profile.id)

        let oldLiveCount = try db.dbQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM live_poll_batches WHERE profile_id = ? AND snapshot_time = ?",
                arguments: [profile.id.uuidString, oldISO]
            ) ?? 0
        }

        let keptLiveCount = try db.dbQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM live_poll_batches WHERE profile_id = ? AND snapshot_time IN (?, ?)",
                arguments: [profile.id.uuidString, keepAISO, keepBISO]
            ) ?? 0
        }

        let oldCoreCount = try db.dbQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM cpu_core_history WHERE profile_id = ? AND timestamp = ?",
                arguments: [profile.id.uuidString, oldISO]
            ) ?? 0
        }

        let keptCoreCount = try db.dbQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM cpu_core_history WHERE profile_id = ? AND timestamp IN (?, ?)",
                arguments: [profile.id.uuidString, keepAISO, keepBISO]
            ) ?? 0
        }

        #expect(oldLiveCount == 0)
        #expect(keptLiveCount == 2)

        #expect(oldCoreCount == 0)
        #expect(keptCoreCount == 2)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func databaseRoundTripsClusterOverview() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let profile = ClusterProfile(displayName: "overview", hostname: "hpc", username: "alice")
        try db.saveProfile(profile)

        let overview = ClusterOverview(
            profileId: profile.id,
            fetchedAt: Date(),
            totalNodes: 120,
            partitionCount: 4,
            partitions: ["cpu", "gpu", "fat", "vdi"],
            idleNodes: 40,
            mixedNodes: 20,
            allocatedNodes: 50,
            drainingNodes: 3,
            reservedNodes: 2,
            downNodes: 4,
            failedNodes: 1,
            unknownNodes: 0,
            downNodeNames: ["node101", "node102"],
            failedNodeNames: ["node090"],
            reservedNodeNames: ["node010", "node011"],
            drainingNodeNames: ["node070"]
        )

        try db.saveClusterOverview(overview)
        let loaded = try db.latestClusterOverview(profileId: profile.id)

        #expect(loaded?.totalNodes == 120)
        #expect(loaded?.partitionCount == 4)
        #expect(loaded?.downNodes == 4)
        #expect(loaded?.failedNodeNames == ["node090"])
        #expect(loaded?.reservedNodeNames == ["node010", "node011"])

        try? FileManager.default.removeItem(atPath: path)
    }
}
