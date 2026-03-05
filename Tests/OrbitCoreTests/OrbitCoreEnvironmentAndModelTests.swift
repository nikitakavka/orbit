import Foundation
import Testing
@testable import OrbitCore

struct OrbitCoreEnvironmentAndModelTests {
    @Test
    func slurmVersionParsing() {
        let a = SlurmVersion(parsing: "slurm 24.11.0")
        #expect(a?.major == 24)
        #expect(a?.minor == 11)
        #expect(a?.patch == 0)
        #expect(a?.supportsJSON == true)

        let b = SlurmVersion(parsing: "slurm-20.11.8")
        #expect(b?.supportsJSON == false)
    }

    @Test
    func orbitEnvironmentAuditFlagDefaultsToDisabled() throws {
        let suite = "orbit-test-env-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            #expect(Bool(false))
            return
        }
        defaults.removePersistentDomain(forName: suite)

        #expect(OrbitEnvironment.auditEnabled(env: [:], userDefaults: defaults) == false)
        #expect(OrbitEnvironment.auditEnabled(env: ["ORBIT_ENABLE_AUDIT": "1"], userDefaults: defaults) == true)
        #expect(OrbitEnvironment.auditEnabled(env: ["ORBIT_ENABLE_AUDIT": "0"], userDefaults: defaults) == false)

        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func profileStatusComputesArrayProgressSummary() {
        let profile = ClusterProfile(displayName: "array", hostname: "hpc", username: "alice")
        let parent = JobSnapshot(
            id: "226873",
            profileId: profile.id,
            name: "ag4_nenepo_job",
            state: .pending,
            partition: "gpu5x",
            nodes: 1,
            cpus: 2,
            timeUsed: 0,
            timeLimit: 600,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: "Resources",
            isArray: true,
            arrayParentID: "226873",
            arrayTasksDone: 12,
            arrayTasksTotal: 20,
            snapshotTime: Date()
        )

        let child1 = JobSnapshot(
            id: "226874",
            profileId: profile.id,
            name: "ag4_nenepo_job",
            state: .running,
            partition: "gpu5x",
            nodes: 1,
            cpus: 2,
            timeUsed: 10,
            timeLimit: 600,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayParentID: "226873",
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        let child2 = JobSnapshot(
            id: "226875",
            profileId: profile.id,
            name: "ag4_nenepo_job",
            state: .running,
            partition: "gpu5x",
            nodes: 1,
            cpus: 2,
            timeUsed: 11,
            timeLimit: 600,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: false,
            arrayParentID: "226873",
            arrayTasksDone: 0,
            arrayTasksTotal: 0,
            snapshotTime: Date()
        )

        let status = ProfileStatus(
            profile: profile,
            liveJobs: [parent, child1, child2],
            lastSuccessfulPollAt: Date(),
            sacctAvailable: false,
            sacctNote: nil,
            fairshareScore: nil,
            clusterLoad: nil,
            clusterOverview: nil
        )

        #expect(status.arrayProgress.count == 1)
        let summary = status.arrayProgress[0]
        #expect(summary.parentJobID == "226873")
        #expect(summary.done == 12)
        #expect(summary.total == 20)
        #expect(summary.running == 2)
        #expect(summary.pending == 6)
    }
}
