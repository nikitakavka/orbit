import Foundation

public protocol NotificationEngine {
    func process(diff: JobDiff, profile: ClusterProfile)
}

public struct NoopNotificationEngine: NotificationEngine {
    public init() {}
    public func process(diff: JobDiff, profile: ClusterProfile) {}
}
