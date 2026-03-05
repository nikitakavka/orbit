import Foundation

enum AuditedCommandRunner {
    static func run(
        profile: ClusterProfile,
        command: String,
        database: OrbitDatabase,
        execute: @escaping () async throws -> CommandResult,
        reportInternalError: (String, Error) -> Void
    ) async -> (result: Result<CommandResult, Error>, auditId: Int64?) {
        if !OrbitEnvironment.auditEnabled() {
            do {
                let result = try await execute()
                return (.success(result), nil)
            } catch {
                return (.failure(error), nil)
            }
        }

        var auditId: Int64?

        do {
            auditId = try database.recordAuditStart(profile: profile, command: command)
        } catch {
            reportInternalError("recording audit start", error)
        }

        do {
            let result = try await execute()
            if let auditId {
                do {
                    try database.recordAuditFinish(id: auditId, result: result, error: nil)
                } catch {
                    reportInternalError("recording audit finish success", error)
                }
            }

            return (.success(result), auditId)
        } catch {
            if let auditId {
                do {
                    try database.recordAuditFinish(id: auditId, result: nil, error: error.localizedDescription)
                } catch {
                    reportInternalError("recording audit finish failure", error)
                }
            }

            return (.failure(error), auditId)
        }
    }
}
