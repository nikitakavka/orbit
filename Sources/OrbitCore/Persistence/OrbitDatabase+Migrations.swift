import Foundation
@preconcurrency import GRDB

extension OrbitDatabase {
    func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "cluster_profiles") { t in
                t.column("id", .text).primaryKey()
                t.column("data", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(table: "job_snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profile_id", .text).notNull()
                t.column("job_id", .text).notNull()
                t.column("data", .text).notNull()
                t.column("snapshot_time", .text).notNull()
            }
            try db.create(index: "idx_job_snapshots_profile_time", on: "job_snapshots", columns: ["profile_id", "snapshot_time"])

            try db.create(table: "job_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profile_id", .text).notNull()
                t.column("job_id", .text).notNull()
                t.column("data", .text).notNull()
                t.column("fetched_at", .text).notNull()
            }

            try db.create(table: "fairshare") { t in
                t.column("profile_id", .text).primaryKey()
                t.column("score", .double)
                t.column("fetched_at", .text).notNull()
            }

            try db.create(table: "cluster_load") { t in
                t.column("profile_id", .text).primaryKey()
                t.column("total_cpus", .integer).notNull()
                t.column("allocated_cpus", .integer).notNull()
                t.column("total_nodes", .integer).notNull()
                t.column("allocated_nodes", .integer).notNull()
                t.column("fetched_at", .text).notNull()
            }

            try db.create(table: "cpu_core_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profile_id", .text).notNull()
                t.column("timestamp", .text).notNull()
                t.column("cores_in_use", .integer).notNull()
            }

            try db.create(table: "audit_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .text).notNull()
                t.column("profile_id", .text).notNull()
                t.column("cluster_name", .text).notNull()
                t.column("command", .text).notNull()
                t.column("exit_code", .integer)
                t.column("duration_ms", .integer)
                t.column("error", .text)
                t.column("parse_failed", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "notification_state") { t in
                t.column("job_id", .text).notNull()
                t.column("profile_id", .text).notNull()
                t.column("event_type", .text).notNull()
                t.column("fired_at", .text).notNull()
                t.primaryKey(["job_id", "profile_id", "event_type"])
            }
        }

        migrator.registerMigration("v2_live_poll_batches") { db in
            try db.create(table: "live_poll_batches", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profile_id", .text).notNull()
                t.column("snapshot_time", .text).notNull()
            }
            try db.create(index: "idx_live_poll_batches_profile_time", on: "live_poll_batches", columns: ["profile_id", "snapshot_time"], ifNotExists: true)
        }

        migrator.registerMigration("v3_cluster_capabilities") { db in
            try db.create(table: "cluster_capabilities", ifNotExists: true) { t in
                t.column("profile_id", .text).primaryKey()
                t.column("sacct_available", .integer).notNull().defaults(to: 1)
                t.column("detected_at", .text).notNull()
                t.column("note", .text)
            }
        }

        migrator.registerMigration("v4_history_dedupe") { db in
            try db.execute(
                sql: """
                DELETE FROM job_history
                WHERE id NOT IN (
                    SELECT MAX(id)
                    FROM job_history
                    GROUP BY profile_id, job_id
                )
                """
            )

            try db.create(
                index: "idx_job_history_profile_job_unique",
                on: "job_history",
                columns: ["profile_id", "job_id"],
                unique: true,
                ifNotExists: true
            )
            try db.create(index: "idx_job_history_fetched_at", on: "job_history", columns: ["fetched_at"], ifNotExists: true)
            try db.create(index: "idx_notification_state_fired_at", on: "notification_state", columns: ["fired_at"], ifNotExists: true)
        }

        migrator.registerMigration("v5_cluster_overview") { db in
            try db.create(table: "cluster_overview", ifNotExists: true) { t in
                t.column("profile_id", .text).primaryKey()
                t.column("data", .text).notNull()
                t.column("fetched_at", .text).notNull()
            }
        }

        migrator.registerMigration("v6_profile_lookup_and_snapshot_indexes") { db in
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_cluster_profiles_display_name ON cluster_profiles(json_extract(data, '$.displayName'))"
            )

            try db.create(
                index: "idx_job_snapshots_profile_job_id",
                on: "job_snapshots",
                columns: ["profile_id", "job_id", "id"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v7_array_progress") { db in
            try db.create(table: "array_progress", ifNotExists: true) { t in
                t.column("profile_id", .text).notNull()
                t.column("array_parent_id", .text).notNull()
                t.column("total", .integer).notNull()
                t.column("finished", .integer).notNull()
                t.column("total_is_exact", .integer).notNull().defaults(to: 0)
                t.column("updated_at", .text).notNull()
                t.primaryKey(["profile_id", "array_parent_id"])
            }
            try db.create(
                index: "idx_array_progress_updated_at",
                on: "array_progress",
                columns: ["updated_at"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v8_array_progress_source") { db in
            guard try db.columns(in: "array_progress").allSatisfy({ $0.name != "source" }) else {
                return
            }
            try db.alter(table: "array_progress") { t in
                t.add(column: "source", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v9_array_progress_provenance") { db in
            let columns = try db.columns(in: "array_progress").map(\.name)
            if !columns.contains("total_source") {
                try db.alter(table: "array_progress") { t in
                    t.add(column: "total_source", .integer).notNull().defaults(to: 0)
                }
            }
            if !columns.contains("finished_source") {
                try db.alter(table: "array_progress") { t in
                    t.add(column: "finished_source", .integer).notNull().defaults(to: 0)
                }
            }

            // v8 used 0=queue, 1=batch script, 2=accounting for both
            // independent facts. Preserve that provenance while splitting it.
            try db.execute(
                sql: """
                UPDATE array_progress
                SET total_source = CASE source WHEN 2 THEN 3 ELSE source END,
                    finished_source = CASE source WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE 0 END
                """
            )
        }

        try migrator.migrate(dbQueue)
    }
}
