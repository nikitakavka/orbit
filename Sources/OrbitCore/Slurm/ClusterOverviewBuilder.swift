import Foundation

public enum ClusterOverviewBuilder {
    public static func build(
        profileId: UUID,
        inventory: NodeInventoryResult,
        fetchedAt: Date = Date()
    ) -> ClusterOverview {
        var idleNodes = 0
        var mixedNodes = 0
        var allocatedNodes = 0
        var drainingNodes = 0
        var reservedNodes = 0
        var downNodes = 0
        var failedNodes = 0
        var unknownNodes = 0

        var downNodeNames: [String] = []
        var failedNodeNames: [String] = []
        var reservedNodeNames: [String] = []
        var drainingNodeNames: [String] = []

        for node in inventory.nodes {
            let tokens = stateTokens(from: node.state)

            let isDown = hasAny(tokens, ["DOWN"])
            let isFailed = hasAny(tokens, ["FAIL", "FAILING", "FAILG", "INVAL", "NOT_RESPONDING", "NO_RESPOND", "NODE_FAIL"])
            let isDraining = hasAny(tokens, ["DRAIN", "DRAINING", "DRAINED", "DRNG", "MAINT"])
            let isReserved = hasAny(tokens, ["RESERVED", "RESV"])
            let isIdle = hasAny(tokens, ["IDLE"])
            let isMixed = hasAny(tokens, ["MIXED", "MIX"])
            let isAllocated = hasAny(tokens, ["ALLOCATED", "ALLOC"])

            if isDown {
                downNodes += 1
                downNodeNames.append(node.name)
            }

            if isFailed {
                failedNodes += 1
                failedNodeNames.append(node.name)
            }

            if isDraining {
                drainingNodes += 1
                drainingNodeNames.append(node.name)
            }

            if isReserved {
                reservedNodes += 1
                reservedNodeNames.append(node.name)
            }

            if isIdle { idleNodes += 1 }
            if isMixed { mixedNodes += 1 }
            if isAllocated { allocatedNodes += 1 }

            if !isDown && !isFailed && !isDraining && !isReserved && !isIdle && !isMixed && !isAllocated {
                unknownNodes += 1
            }
        }

        var partitionNames = Set(inventory.partitions.map(\.name))
        for node in inventory.nodes {
            for partition in node.partitions {
                partitionNames.insert(partition)
            }
        }

        let partitions = partitionNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        return ClusterOverview(
            profileId: profileId,
            fetchedAt: fetchedAt,
            totalNodes: inventory.nodes.count,
            partitionCount: partitions.count,
            partitions: partitions,
            idleNodes: idleNodes,
            mixedNodes: mixedNodes,
            allocatedNodes: allocatedNodes,
            drainingNodes: drainingNodes,
            reservedNodes: reservedNodes,
            downNodes: downNodes,
            failedNodes: failedNodes,
            unknownNodes: unknownNodes,
            downNodeNames: downNodeNames.sorted(),
            failedNodeNames: failedNodeNames.sorted(),
            reservedNodeNames: reservedNodeNames.sorted(),
            drainingNodeNames: drainingNodeNames.sorted()
        )
    }

    private static func hasAny(_ tokens: Set<String>, _ states: [String]) -> Bool {
        states.contains { tokens.contains($0) }
    }

    private static func stateTokens(from raw: String) -> Set<String> {
        Set(
            raw.uppercased()
                .split(whereSeparator: { !$0.isLetter && $0 != "_" })
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }
}
