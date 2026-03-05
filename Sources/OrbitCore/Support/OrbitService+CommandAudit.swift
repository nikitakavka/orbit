import Foundation

extension OrbitService {
    func runAuditedCommand(
        profile: ClusterProfile,
        connection: SSHConnection,
        command: String
    ) async throws -> CommandResult {
        let execution = await AuditedCommandRunner.run(
            profile: profile,
            command: command,
            database: database,
            execute: {
                try await connection.run(command)
            },
            reportInternalError: { context, error in
                self.reportInternalError(context, error: error)
            }
        )

        switch execution.result {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func validateProfileSupportsJSON(_ profile: ClusterProfile) throws {
        if profile.outputMode == .legacy {
            throw OrbitServiceError.legacySlurmUnsupported
        }
    }

    func parsePartitions(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*", with: "") }
            .filter { !$0.isEmpty }
    }

    func isAccountingStorageDisabled(_ text: String) -> Bool {
        SlurmErrorClassifier.isAccountingStorageDisabled(text)
    }

    func reportInternalError(_ context: String, error: Error) {
        OrbitDiagnostics.report(component: "OrbitService", context: context, error: error)
    }
}
