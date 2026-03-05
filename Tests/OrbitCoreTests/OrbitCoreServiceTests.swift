import Foundation
import Testing
@testable import OrbitCore

struct OrbitCoreServiceTests {
    @Test
    func serviceRejectsLegacyProfilePoll() async throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let service = OrbitService(database: db)

        let profile = ClusterProfile(
            displayName: "legacy",
            hostname: "hpc",
            username: "alice",
            outputMode: .legacy
        )
        try service.addProfile(profile)

        var rejected = false
        do {
            _ = try await service.pollOnce(identifier: profile.id.uuidString)
        } catch OrbitServiceError.legacySlurmUnsupported {
            rejected = true
        }

        #expect(rejected)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func serviceCanEnableDisableProfile() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let service = OrbitService(database: db)

        let profile = ClusterProfile(displayName: "toggle", hostname: "hpc", username: "alice", isActive: true)
        try service.addProfile(profile)

        try service.setProfileActive(identifier: "toggle", isActive: false)
        let disabled = try service.profile(identifier: "toggle")
        #expect(disabled.isActive == false)

        try service.setProfileActive(identifier: "toggle", isActive: true)
        let enabled = try service.profile(identifier: "toggle")
        #expect(enabled.isActive == true)

        try service.deleteProfile(id: profile.id)
        var deleted = false
        do {
            _ = try service.profile(identifier: "toggle")
        } catch {
            deleted = true
        }
        #expect(deleted)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func serviceRejectsDuplicateProfileNamesCaseInsensitive() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let service = OrbitService(database: db)

        let first = ClusterProfile(displayName: "alpha", hostname: "hpc", username: "alice")
        try service.addProfile(first)

        let duplicate = ClusterProfile(displayName: "ALPHA", hostname: "hpc2", username: "alice")

        var rejected = false
        do {
            try service.addProfile(duplicate)
        } catch OrbitServiceError.invalidProfile {
            rejected = true
        }

        #expect(rejected)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func serviceValidatesPortAndGrafanaURL() throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let service = OrbitService(database: db)

        let badPort = ClusterProfile(displayName: "bad-port", hostname: "hpc", port: 70_000, username: "alice")
        let badGrafana = ClusterProfile(displayName: "bad-grafana", hostname: "hpc", username: "alice", grafanaURL: "ftp://grafana.local")

        var rejectedPort = false
        do {
            try service.addProfile(badPort)
        } catch OrbitServiceError.invalidProfile {
            rejectedPort = true
        }

        var rejectedGrafana = false
        do {
            try service.addProfile(badGrafana)
        } catch OrbitServiceError.invalidProfile {
            rejectedGrafana = true
        }

        #expect(rejectedPort)
        #expect(rejectedGrafana)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func serviceStatusReadsCachedData() async throws {
        let path = "/tmp/orbit-test-\(UUID().uuidString).sqlite"
        let db = try OrbitDatabase(path: path)
        let service = OrbitService(database: db)

        let profile = ClusterProfile(displayName: "status", hostname: "hpc", username: "alice")
        try service.addProfile(profile)

        let job = JobSnapshot(
            id: "42",
            profileId: profile.id,
            name: "run",
            state: .running,
            partition: "gpu",
            nodes: 1,
            cpus: 8,
            timeUsed: 120,
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

        try db.saveLive([job], profileId: profile.id)
        try db.saveFairshare(0.5, profileId: profile.id)
        try db.saveClusterLoad(ClusterLoad(profileId: profile.id, totalCPUs: 100, allocatedCPUs: 25, totalNodes: 10, allocatedNodes: 2, fetchedAt: Date()))
        try db.setSacctAvailability(profileId: profile.id, available: false, note: "disabled")

        let status = try await service.status(identifier: "status", refresh: false)
        #expect(status.liveJobs.count == 1)
        #expect(status.runningJobs == 1)
        #expect(status.fairshareScore == 0.5)
        #expect(status.clusterLoad?.totalCPUs == 100)
        #expect(status.sacctAvailable == false)
        #expect(status.sacctNote == "disabled")

        try? FileManager.default.removeItem(atPath: path)
    }
}
