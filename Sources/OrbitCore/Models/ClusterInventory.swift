import Foundation

public struct NodeInventoryEntry: Codable, Equatable {
    public let name: String
    public var state: String
    public var totalCPUs: Int
    public var allocatedCPUs: Int
    public var memoryMB: Int?
    public var memoryAllocatedMB: Int?
    public var memoryFreeMB: Int?
    public var features: String?
    public var gres: String?
    public var gresUsed: String?
    public var partitions: [String]

    public init(
        name: String,
        state: String,
        totalCPUs: Int,
        allocatedCPUs: Int,
        memoryMB: Int?,
        memoryAllocatedMB: Int? = nil,
        memoryFreeMB: Int? = nil,
        features: String?,
        gres: String?,
        gresUsed: String? = nil,
        partitions: [String]
    ) {
        self.name = name
        self.state = state
        self.totalCPUs = totalCPUs
        self.allocatedCPUs = allocatedCPUs
        self.memoryMB = memoryMB
        self.memoryAllocatedMB = memoryAllocatedMB
        self.memoryFreeMB = memoryFreeMB
        self.features = features
        self.gres = gres
        self.gresUsed = gresUsed
        self.partitions = partitions
    }
}

public struct PartitionConfiguration: Codable, Equatable {
    public let name: String
    public var state: String?
    public var configuredNodes: String?
    public var totalCPUs: Int?
    public var defaultMemoryPerCPUMB: Int?
    public var defaultTimeMinutes: Int?
    public var maxTimeMinutes: Int?
    public var tresConfigured: String?
}

public struct NodeInventoryResult: Codable, Equatable {
    public let nodes: [NodeInventoryEntry]
    public let partitions: [PartitionConfiguration]
}
