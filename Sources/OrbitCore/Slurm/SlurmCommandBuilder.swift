import Foundation

public enum SlurmCommandBuilderError: Error, LocalizedError {
    case invalidUsername
    case invalidJobID

    public var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Username failed allowlist validation"
        case .invalidJobID: return "Job ID failed allowlist validation"
        }
    }
}

public struct SlurmCommandBuilder {
    public static let slurmVersionCommand = "sinfo --version"
    public static let partitionsCommand = "sinfo -h -o \"%P\""
    public static let tmuxCheckCommand = "which tmux"

    public let mode: SlurmOutputMode
    public let username: String

    public init(mode: SlurmOutputMode, username: String) throws {
        guard Self.isValidUsername(username) else { throw SlurmCommandBuilderError.invalidUsername }
        self.mode = mode
        self.username = username
    }

    public var squeueCommand: String {
        switch mode {
        case .json, .unknown:
            return "squeue --user=\(username) --json"
        case .legacy:
            return "squeue --user=\(username) -o \"%.18i %.9P %.8j %.8u %.2t %.10M %.10L %.6D %R\""
        }
    }

    public var sacctCommand: String {
        switch mode {
        case .json, .unknown:
            return "sacct --user=\(username) --starttime=now-24hours --json"
        case .legacy:
            return "sacct --user=\(username) --starttime=now-24hours --format=JobID,JobName,State,Elapsed,Timelimit,CPUTime,MaxRSS,ExitCode --parsable2 --noheader"
        }
    }

    public var sshareCommand: String {
        switch mode {
        case .json, .unknown:
            return "sshare --user=\(username) --json"
        case .legacy:
            return "sshare --user=\(username) -h -o \"%u %F %r\""
        }
    }

    public var clusterLoadCommand: String {
        switch mode {
        case .json, .unknown:
            return "sinfo -N --json"
        case .legacy:
            return "sinfo -N -o \"%20N %10T %10e %10m %20C\""
        }
    }

    public func estimatedStartCommand(jobId: String) throws -> String {
        guard Self.isValidJobID(jobId) else { throw SlurmCommandBuilderError.invalidJobID }
        return "squeue --start --job=\(jobId) --noheader -o \"%S\""
    }

    public static func isValidUsername(_ value: String) -> Bool {
        value.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil
    }

    public static func isValidJobID(_ value: String) -> Bool {
        value.range(of: #"^[0-9_\[\]-]+$"#, options: .regularExpression) != nil
    }
}
