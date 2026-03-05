import Foundation

public struct ClusterOverview: Codable, Equatable {
    public let profileId: UUID
    public let fetchedAt: Date

    public var totalNodes: Int
    public var partitionCount: Int
    public var partitions: [String]

    public var idleNodes: Int
    public var mixedNodes: Int
    public var allocatedNodes: Int
    public var drainingNodes: Int
    public var reservedNodes: Int
    public var downNodes: Int
    public var failedNodes: Int
    public var unknownNodes: Int

    public var downNodeNames: [String]
    public var failedNodeNames: [String]
    public var reservedNodeNames: [String]
    public var drainingNodeNames: [String]

    public init(
        profileId: UUID,
        fetchedAt: Date,
        totalNodes: Int,
        partitionCount: Int,
        partitions: [String],
        idleNodes: Int,
        mixedNodes: Int,
        allocatedNodes: Int,
        drainingNodes: Int,
        reservedNodes: Int,
        downNodes: Int,
        failedNodes: Int,
        unknownNodes: Int,
        downNodeNames: [String],
        failedNodeNames: [String],
        reservedNodeNames: [String],
        drainingNodeNames: [String]
    ) {
        self.profileId = profileId
        self.fetchedAt = fetchedAt
        self.totalNodes = totalNodes
        self.partitionCount = partitionCount
        self.partitions = partitions
        self.idleNodes = idleNodes
        self.mixedNodes = mixedNodes
        self.allocatedNodes = allocatedNodes
        self.drainingNodes = drainingNodes
        self.reservedNodes = reservedNodes
        self.downNodes = downNodes
        self.failedNodes = failedNodes
        self.unknownNodes = unknownNodes
        self.downNodeNames = downNodeNames
        self.failedNodeNames = failedNodeNames
        self.reservedNodeNames = reservedNodeNames
        self.drainingNodeNames = drainingNodeNames
    }
}
