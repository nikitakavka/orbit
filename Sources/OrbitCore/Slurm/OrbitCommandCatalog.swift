import Foundation

public struct OrbitAllowlistedCommand: Sendable {
    public let transparencyTemplate: String
    public let regexPattern: String

    public init(transparencyTemplate: String, regexPattern: String) {
        self.transparencyTemplate = transparencyTemplate
        self.regexPattern = regexPattern
    }
}

public enum OrbitCommandCatalog {
    public static let commands: [OrbitAllowlistedCommand] = [
        OrbitAllowlistedCommand(
            transparencyTemplate: "sinfo --version",
            regexPattern: #"^sinfo --version$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "sinfo -h -o \"%P\"",
            regexPattern: #"^sinfo -h -o "%P"$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "squeue --user={username} --json",
            regexPattern: #"^squeue --user=[a-zA-Z0-9._-]+ --json$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "squeue --user={username} -o \"%.18i %.9P %.8j %.8u %.2t %.10M %.10L %.6D %R\"",
            regexPattern: #"^squeue --user=[a-zA-Z0-9._-]+ -o "%.18i %.9P %.8j %.8u %.2t %.10M %.10L %.6D %R"$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "sacct --user={username} --starttime=now-24hours --json",
            regexPattern: #"^sacct --user=[a-zA-Z0-9._-]+ --starttime=now-24hours --json$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "sacct --user={username} --starttime=now-24hours --format=JobID,JobName,State,Elapsed,Timelimit,CPUTime,MaxRSS,ExitCode --parsable2 --noheader",
            regexPattern: #"^sacct --user=[a-zA-Z0-9._-]+ --starttime=now-24hours --format=JobID,JobName,State,Elapsed,Timelimit,CPUTime,MaxRSS,ExitCode --parsable2 --noheader$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "squeue --start --job={job_id} --noheader -o \"%S\"",
            regexPattern: #"^squeue --start --job=[0-9_\[\]-]+ --noheader -o "%S"$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "sshare --user={username} --json",
            regexPattern: #"^sshare --user=[a-zA-Z0-9._-]+ --json$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "sshare --user={username} -h -o \"%u %F %r\"",
            regexPattern: #"^sshare --user=[a-zA-Z0-9._-]+ -h -o "%u %F %r"$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "sinfo -N --json",
            regexPattern: #"^sinfo -N --json$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "sinfo -N -o \"%20N %10T %10e %10m %20C\"",
            regexPattern: #"^sinfo -N -o "%20N %10T %10e %10m %20C"$"#
        ),
        OrbitAllowlistedCommand(
            transparencyTemplate: "which tmux",
            regexPattern: #"^which tmux$"#
        )
    ]

    public static var transparencyTemplates: [String] {
        commands.map(\.transparencyTemplate)
    }

    public static var allowlistRegexPatterns: [String] {
        commands.map(\.regexPattern)
    }
}
