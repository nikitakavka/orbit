import Foundation

public actor SSHConnectionPool {
    private struct ConnectionConfig: Equatable {
        let hostname: String
        let port: Int
        let username: String
        let sshKeyPath: String?
        let useSSHConfig: Bool
    }

    private var connections: [UUID: SSHConnection] = [:]

    public init() {}

    public func connection(for profile: ClusterProfile) async -> SSHConnection {
        let newConfig = config(for: profile)

        if let existing = connections[profile.id] {
            let existingProfile = await existing.profile
            let existingConfig = config(for: existingProfile)
            if existingConfig == newConfig {
                return existing
            }

            await existing.teardown()
        }

        let created = SSHConnection(profile: profile)
        connections[profile.id] = created
        return created
    }

    public func removeConnection(for profileId: UUID) async {
        guard let existing = connections.removeValue(forKey: profileId) else { return }
        await existing.teardown()
    }

    public func reconnectAllIfNeeded() async {
        for (_, connection) in connections {
            if await !connection.checkAlive() {
                _ = try? await connection.establishMaster()
            }
        }
    }

    public func teardownAll() async {
        for (_, connection) in connections {
            await connection.teardown()
        }
        connections.removeAll()
    }

    private func config(for profile: ClusterProfile) -> ConnectionConfig {
        ConnectionConfig(
            hostname: profile.hostname,
            port: profile.port,
            username: profile.username,
            sshKeyPath: profile.sshKeyPath,
            useSSHConfig: profile.useSSHConfig
        )
    }
}
