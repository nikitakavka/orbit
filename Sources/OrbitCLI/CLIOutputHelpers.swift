import Foundation
import OrbitCore

extension OrbitCLI {
    static func parseOptions(_ args: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var index = 0

        while index < args.count {
            let token = args[index]
            if token.hasPrefix("--") {
                if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                    out[token] = args[index + 1]
                    index += 2
                } else {
                    out[token] = "true"
                    index += 1
                }
            } else {
                index += 1
            }
        }

        return out
    }

    static func prompt(_ label: String) -> String {
        print("\(label): ", terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func formatDuration(_ value: TimeInterval) -> String {
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static func formatAge(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return "\(hours)h \(remMinutes)m"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func statusLine(_ status: ProfileStatus) -> String {
        let activity = status.profile.isActive ? "active" : "inactive"
        let loadText: String
        if let load = status.clusterLoad {
            loadText = String(format: "%.1f%%", load.cpuLoadPercent)
        } else {
            loadText = "-"
        }

        let ageText: String
        if let last = status.lastSuccessfulPollAt {
            ageText = formatAge(Int(Date().timeIntervalSince(last)))
        } else {
            ageText = "never"
        }

        return "- \(status.profile.displayName) [\(activity)] jobs=\(status.liveJobs.count) running=\(status.runningJobs) pending=\(status.pendingJobs) load=\(loadText) last_poll=\(ageText) sacct=\(status.sacctAvailable ? "on" : "off")"
    }

    static func printStatusDetails(_ status: ProfileStatus) {
        print("Profile: \(status.profile.displayName) [\(status.profile.isActive ? "active" : "inactive")]")
        print("Target: \(status.profile.username)@\(status.profile.hostname):\(status.profile.port)")
        print("Mode: \(status.profile.outputMode.rawValue)")

        if let last = status.lastSuccessfulPollAt {
            let iso = ISO8601DateFormatter().string(from: last)
            let age = formatAge(Int(Date().timeIntervalSince(last)))
            print("Last successful poll: \(iso) (\(age) ago)")
        } else {
            print("Last successful poll: never")
        }

        print("Jobs: total=\(status.liveJobs.count), running=\(status.runningJobs), pending=\(status.pendingJobs), terminal=\(status.terminalJobs)")

        if !status.arrayProgress.isEmpty {
            print("Arrays:")
            for array in status.arrayProgress {
                print("- \(array.name) [\(array.parentJobID)] done=\(array.done)/\(array.total) running=\(array.running) pending=\(array.pending)")
            }
        }

        if let score = status.fairshareScore {
            print(String(format: "Fairshare: %.4f", score))
        } else {
            print("Fairshare: n/a")
        }

        if let load = status.clusterLoad {
            print(String(format: "Cluster CPU load: %.2f%% (%d/%d CPUs, nodes %d/%d)", load.cpuLoadPercent, load.allocatedCPUs, load.totalCPUs, load.allocatedNodes, load.totalNodes))
        } else {
            print("Cluster CPU load: n/a")
        }

        if status.sacctAvailable {
            print("sacct history: available")
        } else {
            print("sacct history: disabled")
            if let note = status.sacctNote, !note.isEmpty {
                print("  note: \(note)")
            }
        }
    }

    static func printUsage() {
        print("""
        Orbit CLI

        Commands:
          orbit profile add [--name N --host H --user U --port 22 --key PATH --no-ssh-config --auto-detect-auth --no-test]
          orbit profile list
          orbit profile enable <profile>
          orbit profile disable <profile>
          orbit profile detect-auth --host H --user U
          orbit test <profile>
          orbit poll <profile>
          orbit watch <profile> [--iterations N]
          orbit watch --all [--iterations N]
          orbit nodes <profile>
          orbit status <profile> [--refresh]
          orbit status --all [--active-only] [--refresh]
          orbit audit --last 50
          orbit storage stats
          orbit storage vacuum

        Environment overrides:
          ORBIT_DB_PATH
          ORBIT_ENABLE_NOTIFICATIONS=0   (optional: disable notifications)
          ORBIT_ENABLE_AUDIT=1
          ORBIT_AUDIT_RETENTION_DAYS=8
          ORBIT_HISTORY_RETENTION_DAYS=8
          ORBIT_NOTIFICATION_RETENTION_DAYS=8
          ORBIT_MAX_HISTORY_ENTRIES_PER_POLL=2000
          ORBIT_MAX_DB_SIZE_MB=200
          ORBIT_MAX_COMMAND_OUTPUT_MB=500
        """)
    }

    static func printProfileUsage() {
        print("Usage:")
        print("  orbit profile add [--name N --host H --user U --port 22 --key PATH --no-ssh-config --auto-detect-auth --no-test]")
        print("  orbit profile list")
        print("  orbit profile enable <profile>")
        print("  orbit profile disable <profile>")
        print("  orbit profile detect-auth --host H --user U")
    }

    static func printStorageUsage() {
        print("Usage:")
        print("  orbit storage stats")
        print("  orbit storage vacuum")
    }
}
