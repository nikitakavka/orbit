import Foundation
@preconcurrency import GRDB

extension OrbitDatabase {
    public func arrayProgressRecords(
        profileId: UUID,
        parentJobIDs: [String]
    ) throws -> [String: ArrayProgressRecord] {
        let uniqueIDs = Array(Set(parentJobIDs)).filter { !$0.isEmpty }
        guard !uniqueIDs.isEmpty else { return [:] }

        return try dbQueue.read { db in
            var records: [String: ArrayProgressRecord] = [:]
            for parentJobID in uniqueIDs {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT total, finished, total_is_exact,
                           total_source, finished_source, updated_at
                    FROM array_progress
                    WHERE profile_id = ? AND array_parent_id = ?
                    """,
                    arguments: [profileId.uuidString, parentJobID]
                ) else { continue }

                let total: Int = row["total"]
                let finished: Int = row["finished"]
                let exact: Int = row["total_is_exact"]
                let totalSourceRaw: Int = row["total_source"]
                let finishedSourceRaw: Int = row["finished_source"]
                let updatedAtRaw: String = row["updated_at"]
                let updatedAt = isoFormatter.date(from: updatedAtRaw)
                    ?? ISO8601DateFormatter().date(from: updatedAtRaw)
                    ?? .distantPast

                records[parentJobID] = ArrayProgressRecord(
                    profileId: profileId,
                    parentJobID: parentJobID,
                    total: max(0, total, finished),
                    finished: max(0, finished),
                    totalIsExact: exact == 1,
                    totalSource: ArrayProgressTotalSource(rawValue: totalSourceRaw) ?? .observedQueue,
                    finishedSource: ArrayProgressFinishedSource(rawValue: finishedSourceRaw) ?? .observedQueue,
                    updatedAt: updatedAt
                )
            }
            return records
        }
    }

    @discardableResult
    public func mergeArrayProgress(
        profileId: UUID,
        parentJobID: String,
        total: Int,
        finished: Int,
        totalIsExact: Bool,
        totalSource: ArrayProgressTotalSource = .observedQueue,
        finishedSource: ArrayProgressFinishedSource = .observedQueue
    ) throws -> ArrayProgressRecord {
        let nowDate = Date()
        let now = isoFormatter.string(from: nowDate)
        let cutoff = isoFormatter.string(
            from: nowDate.addingTimeInterval(TimeInterval(-historyRetentionDays * 24 * 60 * 60))
        )
        let safeFinished = max(0, finished)
        let safeTotal = max(0, total, safeFinished)
        let legacySource: Int
        switch totalSource {
        case .observedQueue:
            legacySource = 0
        case .batchScript, .submitLine:
            legacySource = 1
        case .accounting:
            legacySource = 2
        }

        return try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO array_progress (
                    profile_id, array_parent_id, total, finished,
                    total_is_exact, source, total_source, finished_source,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(profile_id, array_parent_id) DO UPDATE SET
                    total = MAX(
                        CASE
                            WHEN excluded.total_source > array_progress.total_source THEN excluded.total
                            WHEN excluded.total_source = array_progress.total_source THEN MAX(array_progress.total, excluded.total)
                            ELSE MAX(array_progress.total, excluded.total)
                        END,
                        array_progress.finished,
                        excluded.finished
                    ),
                    finished = MAX(array_progress.finished, excluded.finished),
                    total_is_exact = CASE
                        WHEN excluded.total_source > array_progress.total_source THEN excluded.total_is_exact
                        WHEN excluded.total_source = array_progress.total_source THEN MAX(array_progress.total_is_exact, excluded.total_is_exact)
                        ELSE array_progress.total_is_exact
                    END,
                    source = MAX(array_progress.source, excluded.source),
                    total_source = MAX(array_progress.total_source, excluded.total_source),
                    finished_source = MAX(array_progress.finished_source, excluded.finished_source),
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    profileId.uuidString,
                    parentJobID,
                    safeTotal,
                    safeFinished,
                    totalIsExact ? 1 : 0,
                    legacySource,
                    totalSource.rawValue,
                    finishedSource.rawValue,
                    now
                ]
            )

            try db.execute(
                sql: "DELETE FROM array_progress WHERE updated_at < ?",
                arguments: [cutoff]
            )

            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT total, finished, total_is_exact,
                       total_source, finished_source
                FROM array_progress
                WHERE profile_id = ? AND array_parent_id = ?
                """,
                arguments: [profileId.uuidString, parentJobID]
            ) else {
                return ArrayProgressRecord(
                    profileId: profileId,
                    parentJobID: parentJobID,
                    total: safeTotal,
                    finished: safeFinished,
                    totalIsExact: totalIsExact,
                    totalSource: totalSource,
                    finishedSource: finishedSource,
                    updatedAt: nowDate
                )
            }

            let mergedTotal: Int = row["total"]
            let mergedFinished: Int = row["finished"]
            let mergedExact: Int = row["total_is_exact"]
            let mergedTotalSourceRaw: Int = row["total_source"]
            let mergedFinishedSourceRaw: Int = row["finished_source"]
            return ArrayProgressRecord(
                profileId: profileId,
                parentJobID: parentJobID,
                total: max(0, mergedTotal, mergedFinished),
                finished: max(0, mergedFinished),
                totalIsExact: mergedExact == 1,
                totalSource: ArrayProgressTotalSource(rawValue: mergedTotalSourceRaw) ?? .observedQueue,
                finishedSource: ArrayProgressFinishedSource(rawValue: mergedFinishedSourceRaw) ?? .observedQueue,
                updatedAt: nowDate
            )
        }
    }
}
