import Foundation
import Testing
@testable import OrbitCore

struct OrbitCoreJobDiffTests {
    @Test
    func jobDifferInfersFinishedForDisappearedRunningJob() {
        let profileID = UUID()
        let running = makeJob(
            id: "9001",
            profileID: profileID,
            name: "fast_job",
            state: .running
        )

        let diff = JobDiffer.diff(previous: [running], current: [])

        #expect(diff.inferredFinished.count == 1)
        #expect(diff.inferredFinished.first?.id == "9001")
    }

    @Test
    func jobDifferInfersArrayFinishOnlyOnceWhenParentAndChildrenDisappear() {
        let profileID = UUID()

        let parent = makeJob(
            id: "500",
            profileID: profileID,
            name: "array_job",
            state: .pending,
            isArray: true,
            arrayParentID: "500",
            arrayTasksDone: 7,
            arrayTasksTotal: 20
        )

        let child = makeJob(
            id: "501",
            profileID: profileID,
            name: "array_job",
            state: .running,
            isArray: false,
            arrayParentID: "500"
        )

        let diff = JobDiffer.diff(previous: [parent, child], current: [])

        #expect(diff.inferredFinished.count == 1)
        #expect(diff.inferredFinished.first?.id == "500")
    }

    @Test
    func jobDifferDoesNotInferArrayFinishWhileArrayStillVisible() {
        let profileID = UUID()

        let parent = makeJob(
            id: "700",
            profileID: profileID,
            name: "array_job",
            state: .pending,
            isArray: true,
            arrayParentID: "700",
            arrayTasksDone: 1,
            arrayTasksTotal: 5
        )

        let childStillVisible = makeJob(
            id: "701",
            profileID: profileID,
            name: "array_job",
            state: .running,
            isArray: false,
            arrayParentID: "700"
        )

        let diff = JobDiffer.diff(previous: [parent, childStillVisible], current: [childStillVisible])

        #expect(diff.inferredFinished.isEmpty)
    }

    @Test
    func jobDifferInfersFinishedForDisappearedPendingJob() {
        let profileID = UUID()
        let pending = makeJob(
            id: "9100",
            profileID: profileID,
            name: "short_pending_job",
            state: .pending
        )

        let diff = JobDiffer.diff(previous: [pending], current: [])

        #expect(diff.inferredFinished.count == 1)
        #expect(diff.inferredFinished.first?.id == "9100")
    }

    @Test
    func jobDifferInfersFinishedForDisappearedCompletedJob() {
        let profileID = UUID()
        let completed = makeJob(
            id: "9200",
            profileID: profileID,
            name: "done_job",
            state: .completed
        )

        let diff = JobDiffer.diff(previous: [completed], current: [])

        #expect(diff.inferredFinished.count == 1)
        #expect(diff.inferredFinished.first?.id == "9200")
    }

    @Test
    func jobDifferInfersArrayByUnderscoreParentPattern() {
        let profileID = UUID()

        let childA = makeJob(
            id: "12000_1",
            profileID: profileID,
            name: "array_like",
            state: .pending
        )

        let childB = makeJob(
            id: "12000_2",
            profileID: profileID,
            name: "array_like",
            state: .pending
        )

        let diffWhileVisible = JobDiffer.diff(previous: [childA, childB], current: [childB])
        #expect(diffWhileVisible.inferredFinished.isEmpty)

        let diffAfterGone = JobDiffer.diff(previous: [childA], current: [])
        #expect(diffAfterGone.inferredFinished.count == 1)
        #expect(diffAfterGone.inferredFinished.first?.id == "12000_1")
    }

    private func makeJob(
        id: String,
        profileID: UUID,
        name: String,
        state: JobState,
        isArray: Bool = false,
        arrayParentID: String? = nil,
        arrayTasksDone: Int = 0,
        arrayTasksTotal: Int = 0
    ) -> JobSnapshot {
        JobSnapshot(
            id: id,
            profileId: profileID,
            name: name,
            state: state,
            partition: "main",
            nodes: 1,
            cpus: 1,
            timeUsed: 30,
            timeLimit: 300,
            submitTime: nil,
            startTime: nil,
            estimatedStartTime: nil,
            pendingReason: nil,
            isArray: isArray,
            arrayParentID: arrayParentID,
            arrayTasksDone: arrayTasksDone,
            arrayTasksTotal: arrayTasksTotal,
            snapshotTime: Date()
        )
    }
}
