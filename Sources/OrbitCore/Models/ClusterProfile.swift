import Foundation

public struct ClusterProfile: Codable, Identifiable, Equatable {
    public let id: UUID
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var sshKeyPath: String?
    public var useSSHConfig: Bool
    public var outputMode: SlurmOutputMode
    public var slurmVersion: String?
    public var pollIntervalSeconds: Int
    public var extendedPollIntervalSeconds: Int
    public var fairshareEnabled: Bool
    public var notifyOnComplete: Bool
    public var notifyOnFail: Bool
    public var notifyOnTimeWarningMinutes: Int
    public var grafanaURL: String?
    public var isActive: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        sshKeyPath: String? = nil,
        useSSHConfig: Bool = true,
        outputMode: SlurmOutputMode = .unknown,
        slurmVersion: String? = nil,
        pollIntervalSeconds: Int = 30,
        extendedPollIntervalSeconds: Int = 300,
        fairshareEnabled: Bool = true,
        notifyOnComplete: Bool = true,
        notifyOnFail: Bool = true,
        notifyOnTimeWarningMinutes: Int = 15,
        grafanaURL: String? = nil,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.sshKeyPath = sshKeyPath
        self.useSSHConfig = useSSHConfig
        self.outputMode = outputMode
        self.slurmVersion = slurmVersion
        self.pollIntervalSeconds = max(1, pollIntervalSeconds)
        self.extendedPollIntervalSeconds = max(1, extendedPollIntervalSeconds)
        self.fairshareEnabled = fairshareEnabled
        self.notifyOnComplete = notifyOnComplete
        self.notifyOnFail = notifyOnFail
        self.notifyOnTimeWarningMinutes = max(0, notifyOnTimeWarningMinutes)
        self.grafanaURL = grafanaURL
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
