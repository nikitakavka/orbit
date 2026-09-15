import Foundation

public struct CommandResult: Codable {
    public let command: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timestamp: Date
    public let durationMs: Int
}

public enum SSHConnectionError: Error, LocalizedError {
    case commandFailed(command: String, code: Int32, stderr: String)
    case queryAlreadyRunning(command: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, code, stderr):
            return "SSH command failed (\(code)): \(command)\n\(stderr)"
        case .queryAlreadyRunning(let command):
            return "Another Orbit Slurm query is already running; skipped: \(command)"
        }
    }
}

public actor SSHConnection {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    private let commandTimeoutSeconds = 30
    private let controlCommandTimeoutSeconds = 10
    private let maxSlurmOutputBytes = 64 * 1024 * 1024
    private let maxAccountingOutputBytes = 16 * 1024 * 1024

    public let profile: ClusterProfile
    private let socketPath: String
    public private(set) var state: State = .disconnected

    public init(profile: ClusterProfile) {
        self.profile = profile
        // A control socket must have exactly one owning master. Including the
        // process ID prevents stable, preview, and CLI processes from racing to
        // create or tear down the same socket.
        self.socketPath = "/tmp/orbit-\(ProcessInfo.processInfo.processIdentifier)-\(Self.shortHash(from: profile.id.uuidString)).sock"
    }

    public func establishMaster() async throws {
        state = .connecting

        var args: [String] = [
            "-M",
            "-S", socketPath,
            "-o", "ControlPersist=60",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]

        if let keyPath = profile.sshKeyPath, !keyPath.isEmpty {
            args += ["-i", keyPath]
        }

        if !profile.useSSHConfig || profile.port != 22 {
            args += ["-p", String(profile.port)]
        }

        args += ["-f", "-N", target]

        let result = try await CommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: args,
            timeoutSeconds: controlCommandTimeoutSeconds,
            maxOutputBytes: Self.resolvedMaxCommandOutputBytes()
        )
        if result.exitCode == 0 {
            state = .connected
        } else {
            let msg = result.stderr.isEmpty ? "Failed to establish SSH master" : result.stderr
            state = .error(msg)
            throw SSHConnectionError.commandFailed(command: "/usr/bin/ssh \(args.joined(separator: " "))", code: result.exitCode, stderr: result.stderr)
        }
    }

    public func checkAlive() async -> Bool {
        var args = [
            "-S", socketPath,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-O", "check"
        ]

        if !profile.useSSHConfig || profile.port != 22 {
            args += ["-p", String(profile.port)]
        }

        args += [target]

        guard let result = try? await CommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: args,
            timeoutSeconds: controlCommandTimeoutSeconds,
            maxOutputBytes: Self.resolvedMaxCommandOutputBytes()
        ) else {
            state = .disconnected
            return false
        }

        let alive = result.exitCode == 0
        state = alive ? .connected : .disconnected
        return alive
    }

    public func run(_ command: String, maxOutputBytes: Int? = nil) async throws -> CommandResult {
        try CommandGuard.validate(command)

        if await !checkAlive() {
            try await establishMaster()
        }

        var args = [
            "-S", socketPath,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5"
        ]

        if let keyPath = profile.sshKeyPath, !keyPath.isEmpty {
            args += ["-i", keyPath]
        }

        if !profile.useSSHConfig || profile.port != 22 {
            args += ["-p", String(profile.port)]
        }

        let remoteCommand = Self.protectedRemoteCommand(for: command)
        args += [target, remoteCommand]

        let configuredOutputBytes = maxOutputBytes ?? Self.resolvedMaxCommandOutputBytes()
        let outputLimitBytes: Int
        if command.hasPrefix("sacct ") {
            outputLimitBytes = min(configuredOutputBytes, maxAccountingOutputBytes)
        } else if Self.isSlurmQuery(command) {
            outputLimitBytes = min(configuredOutputBytes, maxSlurmOutputBytes)
        } else {
            outputLimitBytes = configuredOutputBytes
        }
        let result = try await CommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: args,
            timeoutSeconds: commandTimeoutSeconds,
            maxOutputBytes: outputLimitBytes
        )
        let wrapped = CommandResult(
            command: command,
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            timestamp: Date(),
            durationMs: result.durationMs
        )

        if result.exitCode == 75, Self.isSlurmQuery(command) {
            throw SSHConnectionError.queryAlreadyRunning(command: command)
        }
        if result.exitCode != 0 {
            throw SSHConnectionError.commandFailed(command: command, code: result.exitCode, stderr: result.stderr)
        }

        return wrapped
    }

    public func teardown() async {
        var args = [
            "-S", socketPath,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-O", "exit"
        ]

        if !profile.useSSHConfig || profile.port != 22 {
            args += ["-p", String(profile.port)]
        }

        args += [target]

        _ = try? await CommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: args,
            timeoutSeconds: controlCommandTimeoutSeconds,
            maxOutputBytes: Self.resolvedMaxCommandOutputBytes()
        )
        try? FileManager.default.removeItem(atPath: socketPath)
        state = .disconnected
    }

    private var target: String {
        "\(profile.username)@\(profile.hostname)"
    }

    /// The remote timeout remains alive if the local SSH helper is terminated,
    /// and therefore still terminates the Slurm process. `flock` provides a
    /// cross-process, per-remote-user single-flight gate shared by Orbit builds.
    static func protectedRemoteCommand(for command: String) -> String {
        let timedCommand = "timeout -k 2s 15s \(command)"
        guard isSlurmQuery(command) else { return timedCommand }
        return "flock -n -E 75 \"$HOME/.orbit-slurm-query.lock\" \(timedCommand)"
    }

    private static func isSlurmQuery(_ command: String) -> Bool {
        guard let executable = command.split(separator: " ", maxSplits: 1).first else { return false }
        return ["sacct", "scontrol", "sinfo", "squeue", "sshare"].contains(String(executable))
    }

    private static func resolvedMaxCommandOutputBytes() -> Int {
        OrbitEnvironment.maxCommandOutputMB() * 1024 * 1024
    }

    private static func shortHash(from value: String) -> String {
        let data = Data(value.utf8)
        let hash = data.reduce(5381) { ($0 << 5) &+ $0 &+ UInt64($1) }
        return String(hash, radix: 16).prefix(12).description
    }
}
