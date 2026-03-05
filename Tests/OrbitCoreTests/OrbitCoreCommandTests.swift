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

        var rejected = false
        do {
            try CommandGuard.validate("squeue --user=alice --json | jq")
        } catch {
            rejected = true
        }
        #expect(rejected)
    }
}
