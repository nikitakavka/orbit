import Foundation
@preconcurrency import GRDB

public final class OrbitDatabase {
    public let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let isoFormatter = ISO8601DateFormatter()
    private let dbPath: String
    private let auditRetentionDays: Int
    private let historyRetentionDays: Int
    private let notificationRetentionDays: Int
    private let maxHistoryEntriesPerPoll: Int
    private let maxDatabaseSizeBytes: Int64

    private let maxRetentionDays = 8
    private let liveSnapshotRetentionDays = 8
    private let cpuCoreHistoryRetentionDays = 8

    public init(
        path: String,
        auditRetentionDays: Int = 8,
        historyRetentionDays: Int = 8,
        notificationRetentionDays: Int = 8,
        maxHistoryEntriesPerPoll: Int = 2_000,
        maxDatabaseSizeMB: Int = 200
    ) throws {
        self.dbPath = path
        self.auditRetentionDays = min(maxRetentionDays, max(1, auditRetentionDays))
        self.historyRetentionDays = min(maxRetentionDays, max(1, historyRetentionDays))
        self.notificationRetentionDays = min(maxRetentionDays, max(1, notificationRetentionDays))
        self.maxHistoryEntriesPerPoll = max(100, maxHistoryEntriesPerPoll)
        self.maxDatabaseSizeBytes = Int64(max(50, maxDatabaseSizeMB)) * 1024 * 1024

        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    public static func defaultPath() -> String {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("Orbit", isDirectory: true)
        return dir.appendingPathComponent("orbit.sqlite").path
    }

    public func saveProfile(_ profile: ClusterProfile) throws {
        let data = try String(data: encoder.encode(profile), encoding: .utf8) ?? "{}"
        let now = isoFormatter.string(from: Date())

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO cluster_profiles (id, data, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    data = excluded.data,
                    updated_at = excluded.updated_at
                """,
                arguments: [profile.id.uuidString, data, now, now]
            )
        }
    }

    public func listProfiles() throws -> [ClusterProfile] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT data FROM cluster_profiles ORDER BY created_at")
            return try rows.compactMap { row in
                let data: String = row["data"]
                guard let raw = data.data(using: .utf8) else { return nil }
                return try decoder.decode(ClusterProfile.self, from: raw)
            }
        }
    }

    public func loadProfile(_ identifier: String) throws -> ClusterProfile {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw OrbitDatabaseError.profileNotFound(identifier)
        }

        if let uuid = UUID(uuidString: value) {
            let data: String? = try dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT data FROM cluster_profiles WHERE id = ? LIMIT 1",
                    arguments: [uuid.uuidString]
                )
            }

            if let data,
               let raw = data.data(using: .utf8) {
                return try decoder.decode(ClusterProfile.self, from: raw)
            }

            throw OrbitDatabaseError.profileNotFound(identifier)
        }

        let matches: [ClusterProfile] = try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT data FROM cluster_profiles WHERE json_extract(data, '$.displayName') = ? COLLATE NOCASE ORDER BY created_at",
                arguments: [value]
            )

            return try rows.compactMap { row in
                let data: String = row["data"]
                guard let raw = data.data(using: .utf8) else { return nil }
                return try decoder.decode(ClusterProfile.self, from: raw)
            }
        }

        if matches.count == 1, let profile = matches.first {
            return profile
        }

        if matches.count > 1 {
            throw OrbitDatabaseError.ambiguousProfileName(identifier)
        }

        throw OrbitDatabaseError.profileNotFound(identifier)
    }

    public func deleteProfile(id: UUID) throws {
        let pid = id.uuidString

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cluster_profiles WHERE id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM live_poll_batches WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM job_snapshots WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM job_history WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM fairshare WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM cluster_load WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM cluster_overview WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM cpu_core_history WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM audit_log WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM notification_state WHERE profile_id = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM cluster_capabilities WHERE profile_id = ?", arguments: [pid])
        }
    }

    public func recordAuditStart(profile: ClusterProfile, command: String) throws -> Int64 {
        let now = Date()
        let timestamp = isoFormatter.string(from: now)
        let cutoff = isoFormatter.string(from: now.addingTimeInterval(TimeInterval(-auditRetentionDays * 24 * 60 * 60)))

        return try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM audit_log WHERE timestamp < ?",
                arguments: [cutoff]
            )

            try db.execute(
                sql: "INSERT INTO audit_log (timestamp, profile_id, cluster_name, command) VALUES (?, ?, ?, ?)",
                arguments: [timestamp, profile.id.uuidString, profile.displayName, command]
            )

            try self.enforceStorageBudgetIfNeeded(db: db, now: now)
            return db.lastInsertedRowID
        }
    }

    public func recordAuditFinish(id: Int64, result: CommandResult?, error: String?, parseFailed: Bool = false) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE audit_log
                SET exit_code = ?, duration_ms = ?, error = ?, parse_failed = ?
                WHERE id = ?
                """,
                arguments: [result?.exitCode ?? (error == nil ? nil : -1), result?.durationMs, error, parseFailed ? 1 : 0, id]
            )
        }
    }

    public func markParseFailure(id: Int64, rawOutput: String) throws {
        let excerpt = String(rawOutput.prefix(2000))
        let message = "Parse failed. Raw stdout:\n\(excerpt)"

        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE audit_log
                SET parse_failed = 1,
                    error = CASE
                        WHEN error IS NULL OR error = '' THEN ?
                        ELSE error || '\n' || ?
                    END
                WHERE id = ?
                """,
                arguments: [message, message, id]
            )
        }
    }

    public func recentAudit(limit: Int) throws -> [AuditLogEntry] {
        try dbQueue.read { db in
            try AuditLogEntry.fetchAll(db, sql: "SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", arguments: [limit])
        }
    }

    public func saveLive(_ jobs: [JobSnapshot], profileId: UUID) throws {
        let nowDate = Date()
        let timestamp = isoFormatter.string(from: nowDate)
        let profileKey = profileId.uuidString

        let liveRetentionCutoffISO = isoFormatter.string(
            from: nowDate.addingTimeInterval(TimeInterval(-liveSnapshotRetentionDays * 24 * 60 * 60))
        )

        let coreHistoryRetentionCutoffISO = isoFormatter.string(
            from: nowDate.addingTimeInterval(TimeInterval(-cpuCoreHistoryRetentionDays * 24 * 60 * 60))
        )

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO live_poll_batches (profile_id, snapshot_time) VALUES (?, ?)",
                arguments: [profileKey, timestamp]
            )

            for job in jobs {
                let data = try String(data: encoder.encode(job), encoding: .utf8) ?? "{}"
                try db.execute(
                    sql: "INSERT INTO job_snapshots (profile_id, job_id, data, snapshot_time) VALUES (?, ?, ?, ?)",
                    arguments: [profileKey, job.id, data, timestamp]
                )
            }

            try self.pruneLiveSnapshotRetention(
                db: db,
                profileID: profileKey,
                retentionCutoffISO: liveRetentionCutoffISO
            )

            let cores = jobs.filter { $0.state == .running }.reduce(0) { $0 + $1.cpus }
            try db.execute(
                sql: "INSERT INTO cpu_core_history (profile_id, timestamp, cores_in_use) VALUES (?, ?, ?)",
                arguments: [profileKey, timestamp, cores]
            )

            try self.pruneCPUCoreHistoryRetention(
                db: db,
                profileID: profileKey,
                retentionCutoffISO: coreHistoryRetentionCutoffISO
            )

            try self.enforceStorageBudgetIfNeeded(db: db, now: nowDate)
        }
    }

    public func latestLive(for profileId: UUID) throws -> [JobSnapshot] {
        try dbQueue.read { db in
            let latest: String? = try String.fetchOne(
                db,
                sql: "SELECT snapshot_time FROM live_poll_batches WHERE profile_id = ? ORDER BY id DESC LIMIT 1",
                arguments: [profileId.uuidString]
            )

            guard let latest else { return [] }

            let rows = try Row.fetchAll(
                db,
                sql: "SELECT data FROM job_snapshots WHERE profile_id = ? AND snapshot_time = ?",
                arguments: [profileId.uuidString, latest]
            )

            return try rows.compactMap { row in
                let data: String = row["data"]
                guard let raw = data.data(using: .utf8) else { return nil }
                return try decoder.decode(JobSnapshot.self, from: raw)
            }
        }
    }

    public func lastSuccessfulLivePollAt(profileId: UUID) throws -> Date? {
        let latestISO: String? = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT snapshot_time FROM live_poll_batches WHERE profile_id = ? ORDER BY id DESC LIMIT 1",
                arguments: [profileId.uuidString]
            )
        }

        guard let latestISO else { return nil }
        if let date = isoFormatter.date(from: latestISO) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        return fallback.date(from: latestISO)
    }

    public func updateEstimatedStart(date: Date?, jobId: String, profileId: UUID) throws {
        guard let date else { return }

        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, data FROM job_snapshots
                WHERE profile_id = ? AND job_id = ?
                ORDER BY id DESC LIMIT 20
                """,
                arguments: [profileId.uuidString, jobId]
            )

            for row in rows {
                let id: Int64 = row["id"]
                let data: String = row["data"]
                guard let raw = data.data(using: .utf8) else { continue }
                var snapshot = try decoder.decode(JobSnapshot.self, from: raw)
                snapshot.estimatedStartTime = date
                let encoded = try String(data: encoder.encode(snapshot), encoding: .utf8) ?? data
                try db.execute(sql: "UPDATE job_snapshots SET data = ? WHERE id = ?", arguments: [encoded, id])
            }
        }
    }

    public func saveHistory(_ entries: [JobHistorySnapshot], profileId: UUID) throws {
        let nowDate = Date()
        let now = isoFormatter.string(from: nowDate)
        let cutoff = isoFormatter.string(from: nowDate.addingTimeInterval(TimeInterval(-historyRetentionDays * 24 * 60 * 60)))
        let persistedEntries = limitedHistoryEntries(entries)

        try dbQueue.write { db in
            for entry in persistedEntries {
                let data = try String(data: encoder.encode(entry), encoding: .utf8) ?? "{}"
                try db.execute(
                    sql: """
                    INSERT INTO job_history (profile_id, job_id, data, fetched_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(profile_id, job_id) DO UPDATE SET
                        data = excluded.data,
                        fetched_at = excluded.fetched_at
                    """,
                    arguments: [profileId.uuidString, entry.id, data, now]
                )
            }

            try db.execute(
                sql: "DELETE FROM job_history WHERE profile_id = ? AND fetched_at < ?",
                arguments: [profileId.uuidString, cutoff]
            )

            try self.enforceStorageBudgetIfNeeded(db: db, now: nowDate)
        }
    }

    public func latestHistoryEntry(profileId: UUID, jobId: String) throws -> JobHistorySnapshot? {
        try dbQueue.read { db in
            guard let data: String = try String.fetchOne(
                db,
                sql: "SELECT data FROM job_history WHERE profile_id = ? AND job_id = ? ORDER BY fetched_at DESC LIMIT 1",
                arguments: [profileId.uuidString, jobId]
            ) else {
                return nil
            }

            guard let raw = data.data(using: .utf8) else { return nil }
            return try decoder.decode(JobHistorySnapshot.self, from: raw)
        }
    }

    public func historyEntries(profileId: UUID, fetchedSince: Date? = nil) throws -> [JobHistorySnapshot] {
        let profile = profileId.uuidString
        let fetchedSinceISO = fetchedSince.map { isoFormatter.string(from: $0) }

        return try dbQueue.read { db in
            let rows: [Row]
            if let fetchedSinceISO {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT data FROM job_history WHERE profile_id = ? AND fetched_at >= ? ORDER BY fetched_at DESC",
                    arguments: [profile, fetchedSinceISO]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT data FROM job_history WHERE profile_id = ? ORDER BY fetched_at DESC",
                    arguments: [profile]
                )
            }

            return try rows.compactMap { row in
                let data: String = row["data"]
                guard let raw = data.data(using: .utf8) else { return nil }
                return try decoder.decode(JobHistorySnapshot.self, from: raw)
            }
        }
    }

    public func saveFairshare(_ score: Double?, profileId: UUID) throws {
        let now = isoFormatter.string(from: Date())
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO fairshare (profile_id, score, fetched_at)
                VALUES (?, ?, ?)
                ON CONFLICT(profile_id) DO UPDATE SET
                    score = excluded.score,
                    fetched_at = excluded.fetched_at
                """,
                arguments: [profileId.uuidString, score, now]
            )
        }
    }

    public func latestFairshare(profileId: UUID) throws -> Double? {
        try dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT score FROM fairshare WHERE profile_id = ?",
                arguments: [profileId.uuidString]
            )
        }
    }

    public func saveClusterLoad(_ load: ClusterLoad) throws {
        let now = isoFormatter.string(from: load.fetchedAt)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO cluster_load (profile_id, total_cpus, allocated_cpus, total_nodes, allocated_nodes, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(profile_id) DO UPDATE SET
                    total_cpus = excluded.total_cpus,
                    allocated_cpus = excluded.allocated_cpus,
                    total_nodes = excluded.total_nodes,
                    allocated_nodes = excluded.allocated_nodes,
                    fetched_at = excluded.fetched_at
                """,
                arguments: [
                    load.profileId.uuidString,
                    load.totalCPUs,
                    load.allocatedCPUs,
                    load.totalNodes,
                    load.allocatedNodes,
                    now
                ]
            )
        }
    }

    public func latestClusterLoad(profileId: UUID) throws -> ClusterLoad? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT total_cpus, allocated_cpus, total_nodes, allocated_nodes, fetched_at FROM cluster_load WHERE profile_id = ?",
                arguments: [profileId.uuidString]
            ) else {
                return nil
            }

            let fetchedAtString: String = row["fetched_at"]
            let fetchedAt = isoFormatter.date(from: fetchedAtString) ?? ISO8601DateFormatter().date(from: fetchedAtString) ?? Date()

            return ClusterLoad(
                profileId: profileId,
                totalCPUs: row["total_cpus"],
                allocatedCPUs: row["allocated_cpus"],
                totalNodes: row["total_nodes"],
                allocatedNodes: row["allocated_nodes"],
                fetchedAt: fetchedAt
            )
        }
    }

    public func saveClusterOverview(_ overview: ClusterOverview) throws {
        let fetchedAt = isoFormatter.string(from: overview.fetchedAt)
        let data = try String(data: encoder.encode(overview), encoding: .utf8) ?? "{}"

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO cluster_overview (profile_id, data, fetched_at)
                VALUES (?, ?, ?)
                ON CONFLICT(profile_id) DO UPDATE SET
                    data = excluded.data,
                    fetched_at = excluded.fetched_at
                """,
                arguments: [overview.profileId.uuidString, data, fetchedAt]
            )
        }
    }

    public func latestClusterOverview(profileId: UUID) throws -> ClusterOverview? {
        try dbQueue.read { db in
            guard let data: String = try String.fetchOne(
                db,
                sql: "SELECT data FROM cluster_overview WHERE profile_id = ?",
                arguments: [profileId.uuidString]
            ) else {
                return nil
            }

            guard let raw = data.data(using: .utf8) else { return nil }
            return try decoder.decode(ClusterOverview.self, from: raw)
        }
    }

    public func cpuCoreHistory(profileId: UUID, since: Date) throws -> [CPUCoreDataPoint] {
        let sinceISO = isoFormatter.string(from: since)

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT timestamp, cores_in_use FROM cpu_core_history WHERE profile_id = ? AND timestamp >= ? ORDER BY timestamp ASC",
                arguments: [profileId.uuidString, sinceISO]
            )

            return rows.compactMap { row in
                let timestamp: String = row["timestamp"]
                guard let date = isoFormatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else {
                    return nil
                }

                let cores: Int = row["cores_in_use"]
                return CPUCoreDataPoint(profileId: profileId, timestamp: date, totalCoresInUse: cores)
            }
        }
    }

    public func cpuCoreHistory(profileId: UUID, from: Date, to: Date, includePreviousSample: Bool = true) throws -> [CPUCoreDataPoint] {
        let fromISO = isoFormatter.string(from: from)
        let toISO = isoFormatter.string(from: to)

        return try dbQueue.read { db in
            var rows = try Row.fetchAll(
                db,
                sql: "SELECT timestamp, cores_in_use FROM cpu_core_history WHERE profile_id = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp ASC",
                arguments: [profileId.uuidString, fromISO, toISO]
            )

            if includePreviousSample,
               let previous = try Row.fetchOne(
                    db,
                    sql: "SELECT timestamp, cores_in_use FROM cpu_core_history WHERE profile_id = ? AND timestamp < ? ORDER BY timestamp DESC LIMIT 1",
                    arguments: [profileId.uuidString, fromISO]
               ) {
                rows.insert(previous, at: 0)
            }

            return rows.compactMap { row in
                let timestamp: String = row["timestamp"]
                guard let date = isoFormatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else {
                    return nil
                }

                let cores: Int = row["cores_in_use"]
                return CPUCoreDataPoint(profileId: profileId, timestamp: date, totalCoresInUse: cores)
            }
        }
    }

    public func observedCoreUsageSeries(profileId: UUID, from: Date, to: Date, includePreviousSample: Bool = true) throws -> [CPUCoreDataPoint] {
        let fromISO = isoFormatter.string(from: from)
        let toISO = isoFormatter.string(from: to)

        return try dbQueue.read { db in
            var rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    b.snapshot_time AS ts,
                    COALESCE(SUM(
                        CASE
                            WHEN json_extract(s.data, '$.state') IN ('RUNNING', 'COMPLETING')
                            THEN CAST(COALESCE(json_extract(s.data, '$.cpus'), 0) AS INTEGER)
                            ELSE 0
                        END
                    ), 0) AS cores
                FROM live_poll_batches b
                LEFT JOIN job_snapshots s
                  ON s.profile_id = b.profile_id
                 AND s.snapshot_time = b.snapshot_time
                WHERE b.profile_id = ?
                  AND b.snapshot_time >= ?
                  AND b.snapshot_time <= ?
                GROUP BY b.snapshot_time
                ORDER BY b.snapshot_time ASC
                """,
                arguments: [profileId.uuidString, fromISO, toISO]
            )

            if includePreviousSample,
               let previous = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                        b.snapshot_time AS ts,
                        COALESCE(SUM(
                            CASE
                                WHEN json_extract(s.data, '$.state') IN ('RUNNING', 'COMPLETING')
                                THEN CAST(COALESCE(json_extract(s.data, '$.cpus'), 0) AS INTEGER)
                                ELSE 0
                            END
                        ), 0) AS cores
                    FROM live_poll_batches b
                    LEFT JOIN job_snapshots s
                      ON s.profile_id = b.profile_id
                     AND s.snapshot_time = b.snapshot_time
                    WHERE b.profile_id = ?
                      AND b.snapshot_time < ?
                    GROUP BY b.snapshot_time
                    ORDER BY b.snapshot_time DESC
                    LIMIT 1
                    """,
                    arguments: [profileId.uuidString, fromISO]
               ) {
                rows.insert(previous, at: 0)
            }

            return rows.compactMap { row in
                let timestamp: String = row["ts"]
                guard let date = isoFormatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else {
                    return nil
                }

                let cores: Int = row["cores"]
                return CPUCoreDataPoint(profileId: profileId, timestamp: date, totalCoresInUse: cores)
            }
        }
    }

    public func observedLiveJobCount(profileId: UUID, from: Date, to: Date) throws -> Int {
        let fromISO = isoFormatter.string(from: from)
        let toISO = isoFormatter.string(from: to)

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(DISTINCT job_id) FROM job_snapshots WHERE profile_id = ? AND snapshot_time >= ? AND snapshot_time < ?",
                arguments: [profileId.uuidString, fromISO, toISO]
            ) ?? 0
        }
    }

    public func sacctCapability(profileId: UUID) throws -> (available: Bool, note: String?) {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT sacct_available, note FROM cluster_capabilities WHERE profile_id = ?",
                arguments: [profileId.uuidString]
            ) else {
                return (true, nil)
            }

            let available: Int = row["sacct_available"]
            let note: String? = row["note"]
            return (available == 1, note)
        }
    }

    public func isSacctAvailable(profileId: UUID) throws -> Bool {
        try sacctCapability(profileId: profileId).available
    }

    public func setSacctAvailability(profileId: UUID, available: Bool, note: String? = nil) throws {
        let now = isoFormatter.string(from: Date())
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO cluster_capabilities (profile_id, sacct_available, detected_at, note)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(profile_id) DO UPDATE SET
                    sacct_available = excluded.sacct_available,
                    detected_at = excluded.detected_at,
                    note = excluded.note
                """,
                arguments: [profileId.uuidString, available ? 1 : 0, now, note]
            )
        }
    }

    public func notificationAlreadyFired(jobId: String, profileId: UUID, eventType: String) throws -> Bool {
        try dbQueue.read { db in
            let count: Int = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notification_state WHERE job_id = ? AND profile_id = ? AND event_type = ?",
                arguments: [jobId, profileId.uuidString, eventType]
            ) ?? 0
            return count > 0
        }
    }

    public func jobWasSeenRunning(profileId: UUID, jobId: String) throws -> Bool {
        try dbQueue.read { db in
            let count: Int = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM job_snapshots
                WHERE profile_id = ?
                  AND job_id = ?
                  AND json_extract(data, '$.state') IN ('RUNNING', 'COMPLETING')
                """,
                arguments: [profileId.uuidString, jobId]
            ) ?? 0
            return count > 0
        }
    }

    public func arrayWasSeenRunning(profileId: UUID, arrayRootId: String) throws -> Bool {
        try dbQueue.read { db in
            let count: Int = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM job_snapshots
                WHERE profile_id = ?
                  AND json_extract(data, '$.state') IN ('RUNNING', 'COMPLETING')
                  AND (
                        job_id = ?
                     OR json_extract(data, '$.arrayParentID') = ?
                     OR job_id GLOB ?
                  )
                """,
                arguments: [profileId.uuidString, arrayRootId, arrayRootId, "\(arrayRootId)_*"]
            ) ?? 0
            return count > 0
        }
    }

    public func markNotificationFired(jobId: String, profileId: UUID, eventType: String) throws {
        let nowDate = Date()
        let now = isoFormatter.string(from: nowDate)
        let cutoff = isoFormatter.string(from: nowDate.addingTimeInterval(TimeInterval(-notificationRetentionDays * 24 * 60 * 60)))

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO notification_state (job_id, profile_id, event_type, fired_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [jobId, profileId.uuidString, eventType, now]
            )

            try db.execute(
                sql: "DELETE FROM notification_state WHERE fired_at < ?",
                arguments: [cutoff]
            )

            try self.enforceStorageBudgetIfNeeded(db: db, now: nowDate)
        }
    }

    public func storageStats() throws -> OrbitStorageStats {
        let fileSize = currentDatabaseFileSizeBytes()

        return try dbQueue.read { db in
            OrbitStorageStats(
                fileSizeBytes: fileSize,
                profileCount: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cluster_profiles")) ?? 0,
                livePollBatchCount: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM live_poll_batches")) ?? 0,
                jobSnapshotCount: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_snapshots")) ?? 0,
                jobHistoryCount: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_history")) ?? 0,
                auditLogCount: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_log")) ?? 0,
                notificationStateCount: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notification_state")) ?? 0,
                auditRetentionDays: auditRetentionDays,
                historyRetentionDays: historyRetentionDays,
                notificationRetentionDays: notificationRetentionDays,
                maxHistoryEntriesPerPoll: maxHistoryEntriesPerPoll,
                maxDatabaseSizeBytes: maxDatabaseSizeBytes
            )
        }
    }

    public func vacuum() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    private func limitedHistoryEntries(_ entries: [JobHistorySnapshot]) -> [JobHistorySnapshot] {
        guard entries.count > maxHistoryEntriesPerPoll else { return entries }

        return entries
            .sorted {
                let lhs = $0.endTime ?? $0.startTime ?? Date.distantPast
                let rhs = $1.endTime ?? $1.startTime ?? Date.distantPast
                return lhs > rhs
            }
            .prefix(maxHistoryEntriesPerPoll)
            .map { $0 }
    }

    private func enforceStorageBudgetIfNeeded(db: Database, now: Date) throws {
        let pageCount = (try Int.fetchOne(db, sql: "PRAGMA page_count")) ?? 0
        let pageSize = (try Int.fetchOne(db, sql: "PRAGMA page_size")) ?? 0
        let approxSizeBytes = Int64(pageCount) * Int64(pageSize)

        guard approxSizeBytes > maxDatabaseSizeBytes else { return }

        // aggressive safety pruning when DB exceeds configured size budget
        let auditCutoff = isoFormatter.string(from: now.addingTimeInterval(TimeInterval(-auditRetentionDays * 24 * 60 * 60)))
        let historyCutoff = isoFormatter.string(from: now.addingTimeInterval(TimeInterval(-historyRetentionDays * 24 * 60 * 60)))
        let notificationCutoff = isoFormatter.string(from: now.addingTimeInterval(TimeInterval(-notificationRetentionDays * 24 * 60 * 60)))

        try db.execute(sql: "DELETE FROM audit_log WHERE timestamp < ?", arguments: [auditCutoff])
        try db.execute(sql: "DELETE FROM job_history WHERE fetched_at < ?", arguments: [historyCutoff])
        try db.execute(sql: "DELETE FROM notification_state WHERE fired_at < ?", arguments: [notificationCutoff])

        // hard caps as last line of defense for unusually noisy clusters
        try db.execute(
            sql: """
            DELETE FROM job_history
            WHERE id NOT IN (
                SELECT id FROM job_history
                ORDER BY fetched_at DESC
                LIMIT 100000
            )
            """
        )

        try db.execute(
            sql: """
            DELETE FROM live_poll_batches
            WHERE id NOT IN (
                SELECT id FROM live_poll_batches
                ORDER BY id DESC
                LIMIT 500
            )
            """
        )

        try db.execute(
            sql: """
            DELETE FROM job_snapshots
            WHERE snapshot_time NOT IN (
                SELECT snapshot_time FROM live_poll_batches
            )
            """
        )

    }

    private func pruneLiveSnapshotRetention(
        db: Database,
        profileID: String,
        retentionCutoffISO: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM live_poll_batches WHERE profile_id = ? AND snapshot_time < ?",
            arguments: [profileID, retentionCutoffISO]
        )

        try db.execute(
            sql: """
            DELETE FROM job_snapshots
            WHERE profile_id = ?
              AND snapshot_time NOT IN (
                SELECT snapshot_time FROM live_poll_batches
                WHERE profile_id = ?
              )
            """,
            arguments: [profileID, profileID]
        )
    }

    private func pruneCPUCoreHistoryRetention(
        db: Database,
        profileID: String,
        retentionCutoffISO: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM cpu_core_history WHERE profile_id = ? AND timestamp < ?",
            arguments: [profileID, retentionCutoffISO]
        )
    }

    private func currentDatabaseFileSizeBytes() -> Int64 {
        totalFileSize(atPath: dbPath) + totalFileSize(atPath: dbPath + "-wal") + totalFileSize(atPath: dbPath + "-shm")
    }

    private func totalFileSize(atPath path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}
