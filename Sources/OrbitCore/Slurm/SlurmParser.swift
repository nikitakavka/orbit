import Foundation

public enum SlurmParserError: Error, LocalizedError {
    case invalidJSON
    case notImplemented
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Failed to decode SLURM JSON output"
        case .notImplemented:
            return "This parsing path is not supported in the current build"
        case .invalidData(let detail):
            return detail
        }
    }
}

public protocol SlurmParser {
    func parseJobs(_ output: String, profileId: UUID) throws -> [JobSnapshot]
    func parseJobHistory(_ output: String, profileId: UUID) throws -> [JobHistorySnapshot]
    func parseEstimatedStart(_ output: String) -> Date?
    func parseFairshare(_ output: String) -> Double?
    func parseClusterLoad(_ output: String, profileId: UUID) throws -> ClusterLoad
}
