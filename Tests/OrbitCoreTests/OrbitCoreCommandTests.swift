import Foundation
import Testing
@testable import OrbitCore

struct OrbitCoreCommandTests {
    @Test
    func commandExecutorTimesOutLongRunningProcess() async throws {
        var didTimeout = false

        do {
            _ = try await CommandExecutor.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 2"],
                timeoutSeconds: 1
            )
        } catch let error as ProcessExecutionError {
            if case .timedOut = error {
                didTimeout = true
            }
        }

        #expect(didTimeout)
    }

    @Test
    func commandExecutorRejectsOversizedOutput() async throws {
        var didReject = false

        do {
            _ = try await CommandExecutor.run(
                executable: "/bin/sh",
                arguments: ["-c", "yes orbit | head -c 1048576"],
                timeoutSeconds: 5,
                maxOutputBytes: 64 * 1024
            )
        } catch let error as ProcessExecutionError {
            if case .outputTooLarge = error {
                didReject = true
            }
        }

        #expect(didReject)
    }

    @Test
    func commandGuardAllowlist() throws {
        try CommandGuard.validate("squeue --user=alice --json")
        try CommandGuard.validate("sinfo --version")
        try CommandGuard.validate("scontrol write batch_script 777514 -")
        try CommandGuard.validate("sacct --jobs=777514,888000 --allocations --array --json")

        var rejected = false
        do {
            try CommandGuard.validate("squeue --user=alice --json | jq")
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test
    func parsesArraySizeFromCachedBatchScript() {
        let longForm = """
        #!/bin/bash
        #SBATCH --array=0-95%4
        #SBATCH --ntasks=15
        """
        let shortForm = """
        #!/bin/bash
        #SBATCH -a 5-15:2,20,22-23%3
        """

        #expect(SlurmArraySpecificationParser.taskCount(inBatchScript: longForm) == 96)
        #expect(SlurmArraySpecificationParser.taskCount(inBatchScript: shortForm) == 9)
        #expect(SlurmArraySpecificationParser.taskCount(inBatchScript: "#SBATCH --array=\"1-4%2\"") == 4)
        #expect(SlurmArraySpecificationParser.taskCount(inBatchScript: "#!/bin/bash\necho no-array") == nil)
        #expect(SlurmArraySpecificationParser.taskCount(inSubmitLine: "sbatch --array=10-20:2%3 run.sh") == 6)
        #expect(SlurmArraySpecificationParser.taskCount(inSubmitLine: "env FOO=1 sbatch -a '2,4-8:2' run.sh") == 4)
        #expect(SlurmArraySpecificationParser.taskCount(inSubmitLine: "sbatch run.sh") == nil)

        let compactMask = SlurmArraySpecificationParser.taskIDs(inSpecification: "0x3A")
        #expect(compactMask?.count == 4)
        #expect(compactMask?.contains(1) == true)
        #expect(compactMask?.contains(3) == true)
        #expect(compactMask?.contains(4) == true)
        #expect(compactMask?.contains(5) == true)

        let realSlurmMask = SlurmArraySpecificationParser.taskIDs(
            inSpecification: "0xFFFFFFFFFFFFFFFFFE000000"
        )
        #expect(realSlurmMask?.count == 71)
        #expect(realSlurmMask?.first == 25)
        #expect(realSlurmMask?.last == 95)
    }
}
