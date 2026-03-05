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

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, code, stderr):
            return "SSH command failed (\(code)): \(command)\n\(stderr)"
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

    public let profile: ClusterProfile
    private let socketPath: String
    public private(set) var state: State = .disconnected

    public init(profile: ClusterProfile) {
        self.profile = profile
        self.socketPath = "/tmp/orbit-\(Self.shortHash(from: profile.id.uuidString)).sock"
    }

    public func establishMaster() async throws {
        state = .connecting

        var args: [String] = [
            "-M",
            "-S", socketPath,
            "-o", "ControlPersist=600",
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

    public func run(_ command: String) async throws -> CommandResult {
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

        args += [target, command]

        let result = try await CommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: args,
            timeoutSeconds: commandTimeoutSeconds,
            maxOutputBytes: Self.resolvedMaxCommandOutputBytes()
        )
        let wrapped = CommandResult(
            command: command,
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            timestamp: Date(),
            durationMs: result.durationMs
        )

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

    private static func resolvedMaxCommandOutputBytes() -> Int {
        OrbitEnvironment.maxCommandOutputMB() * 1024 * 1024
    }

    private static func shortHash(from value: String) -> String {
        let data = Data(value.utf8)
        let hash = data.reduce(5381) { ($0 << 5) &+ $0 &+ UInt64($1) }
        return String(hash, radix: 16).prefix(12).description
    }
}
