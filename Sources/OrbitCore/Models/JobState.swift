import Foundation

public enum JobState: String, Codable {
    case pending = "PENDING"
    case running = "RUNNING"
    case completing = "COMPLETING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case timeout = "TIMEOUT"
    case outOfMemory = "OUT_OF_MEMORY"
    case unknown

    public static func from(legacyCode: String) -> JobState {
        switch legacyCode {
        case "R": return .running
        case "PD": return .pending
        case "CG": return .completing
        case "CD": return .completed
        case "F": return .failed
        case "CA": return .cancelled
        case "TO": return .timeout
        case "OOM": return .outOfMemory
        default: return .unknown
        }
    }

    public static func from(slurmState: String) -> JobState {
        switch slurmState.uppercased() {
        case "PENDING": return .pending
        case "RUNNING": return .running
        case "COMPLETING": return .completing
        case "COMPLETED": return .completed
        case "FAILED": return .failed
        case "CANCELLED": return .cancelled
        case "TIMEOUT": return .timeout
        case "OUT_OF_MEMORY", "OOM": return .outOfMemory
        default: return .unknown
        }
    }
}
