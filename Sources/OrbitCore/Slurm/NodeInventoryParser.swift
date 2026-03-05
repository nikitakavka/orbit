import Foundation

public enum NodeInventoryParserError: Error, LocalizedError {
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "Unable to parse node inventory output"
        }
    }
}

public enum NodeInventoryParser {
    public static func parse(output: String) throws -> NodeInventoryResult {
        if let jsonData = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let parsed = parseJSON(object) {
            return parsed
        }

        throw NodeInventoryParserError.invalidOutput
    }

    private static func parseJSON(_ root: [String: Any]) -> NodeInventoryResult? {
        if let nodes = root["nodes"] as? [[String: Any]] {
            return parseStandardNodes(nodes)
        }

        if let sinfo = root["sinfo"] as? [[String: Any]] {
            return parseSinfoRows(sinfo)
        }

        return nil
    }

    private static func parseStandardNodes(_ nodes: [[String: Any]]) -> NodeInventoryResult {
        let entries: [NodeInventoryEntry] = nodes.compactMap { node in
            guard let name = anyToString(node["name"] ?? node["hostname"] ?? node["node_name"]), !name.isEmpty else {
                return nil
            }

            let state = parseState(node["state"] ?? node["node_state"] ?? nested(node, ["node", "state"]))
            let totalCPUs = anyToInt(nested(node, ["cpus", "total"]) ?? node["cpus"]) ?? 0
            let allocatedCPUs = anyToInt(nested(node, ["cpus", "allocated"]) ?? node["alloc_cpus"]) ?? 0

            let memoryMB = parseNumeric(node["real_memory"] ?? nested(node, ["memory", "total"]) ?? nested(node, ["memory", "minimum"]) ?? node["memory"])
            let memoryAllocatedRaw = parseNumeric(nested(node, ["memory", "allocated"]) ?? node["alloc_memory"])
            let memoryFreeRaw = parseNumeric(nested(node, ["memory", "free", "minimum", "number"]) ?? nested(node, ["memory", "free"]))
            let memoryAllocated = inferredAllocatedMemory(totalMB: memoryMB, allocatedMB: memoryAllocatedRaw, freeMB: memoryFreeRaw)

            let features = anyToString(nested(node, ["features", "active"]) ?? nested(node, ["features", "total"]) ?? node["features"])
            let gres = anyToString(nested(node, ["gres", "total"]) ?? node["gres"])
            let gresUsed = anyToString(nested(node, ["gres", "used"]) ?? node["gres_used"])

            let partitions: [String]
            if let array = node["partitions"] as? [String] {
                partitions = array
            } else if let value = anyToString(node["partition"]) {
                partitions = [value]
            } else {
                partitions = []
            }

            return NodeInventoryEntry(
                name: name,
                state: state,
                totalCPUs: totalCPUs,
                allocatedCPUs: allocatedCPUs,
                memoryMB: memoryMB,
                memoryAllocatedMB: memoryAllocated,
                memoryFreeMB: memoryFreeRaw,
                features: sanitizeEmpty(features),
                gres: sanitizeEmpty(gres),
                gresUsed: sanitizeEmpty(gresUsed),
                partitions: partitions.sorted()
            )
        }

        return NodeInventoryResult(nodes: entries.sorted { $0.name < $1.name }, partitions: [])
    }

    private static func parseSinfoRows(_ rows: [[String: Any]]) -> NodeInventoryResult {
        var nodesByName: [String: NodeInventoryEntry] = [:]
        var partitionByName: [String: PartitionConfiguration] = [:]

        for row in rows {
            let nodeNames = ((nested(row, ["nodes", "nodes"]) as? [String]) ?? []).filter { !$0.isEmpty }
            let rowNodeCount = max(1, anyToInt(nested(row, ["nodes", "total"])) ?? nodeNames.count)

            let cpus = row["cpus"] as? [String: Any]
            let perNodeTotalCPUs = anyToInt(cpus?["maximum"] ?? cpus?["minimum"]) ?? ((anyToInt(cpus?["total"]) ?? 0) / rowNodeCount)
            let allocatedCPUsTotal = anyToInt(cpus?["allocated"]) ?? 0
            let perNodeAllocated = allocatedCPUsTotal / rowNodeCount

            let memory = row["memory"] as? [String: Any]
            let perNodeMemoryMB = parseNumeric(memory?["maximum"] ?? memory?["minimum"]) ?? parseNumeric(memory?["total"])

            let rowAllocatedMemoryTotal = parseNumeric(memory?["allocated"])
            let rowFreeMemoryTotal = parseNumeric(memory?["free"] ?? nested(row, ["memory", "free", "minimum", "number"]))
            let perNodeAllocatedMemory = rowAllocatedMemoryTotal.map { max(0, $0 / rowNodeCount) }
            let perNodeFreeMemory = rowFreeMemoryTotal.map { max(0, $0 / rowNodeCount) }
            let inferredPerNodeAllocated = inferredAllocatedMemory(
                totalMB: perNodeMemoryMB,
                allocatedMB: perNodeAllocatedMemory,
                freeMB: perNodeFreeMemory
            )

            let state = parseState(nested(row, ["node", "state"]) ?? row["state"])
            let features = anyToString(nested(row, ["features", "active"]) ?? nested(row, ["features", "total"]))
            let gres = anyToString(nested(row, ["gres", "total"]))
            let gresUsed = anyToString(nested(row, ["gres", "used"]) ?? row["gres_used"])
            let partitionName = anyToString(nested(row, ["partition", "name"]))

            for name in nodeNames {
                if var existing = nodesByName[name] {
                    if let partitionName, !existing.partitions.contains(partitionName) {
                        existing.partitions.append(partitionName)
                        existing.partitions.sort()
                    }
                    if existing.gres == nil {
                        existing.gres = sanitizeEmpty(gres)
                    }
                    if existing.gresUsed == nil {
                        existing.gresUsed = sanitizeEmpty(gresUsed)
                    }
                    nodesByName[name] = existing
                } else {
                    nodesByName[name] = NodeInventoryEntry(
                        name: name,
                        state: state,
                        totalCPUs: max(0, perNodeTotalCPUs),
                        allocatedCPUs: max(0, perNodeAllocated),
                        memoryMB: perNodeMemoryMB,
                        memoryAllocatedMB: inferredPerNodeAllocated,
                        memoryFreeMB: perNodeFreeMemory,
                        features: sanitizeEmpty(features),
                        gres: sanitizeEmpty(gres),
                        gresUsed: sanitizeEmpty(gresUsed),
                        partitions: partitionName.map { [$0] } ?? []
                    )
                }
            }

            if let partitionName, partitionByName[partitionName] == nil {
                let partitionState = parseState(nested(row, ["partition", "partition", "state"]))
                partitionByName[partitionName] = PartitionConfiguration(
                    name: partitionName,
                    state: partitionState.isEmpty ? nil : partitionState,
                    configuredNodes: anyToString(nested(row, ["partition", "nodes", "configured"])),
                    totalCPUs: anyToInt(nested(row, ["partition", "cpus", "total"])),
                    defaultMemoryPerCPUMB: anyToInt(nested(row, ["partition", "defaults", "partition_memory_per_cpu", "number"])),
                    defaultTimeMinutes: anyToInt(nested(row, ["partition", "defaults", "time", "number"])),
                    maxTimeMinutes: anyToInt(nested(row, ["partition", "maximums", "time", "number"])),
                    tresConfigured: anyToString(nested(row, ["partition", "tres", "configured"]))
                )
            }
        }

        let nodes = nodesByName.values.sorted { $0.name < $1.name }
        let partitions = partitionByName.values.sorted { $0.name < $1.name }
        return NodeInventoryResult(nodes: nodes, partitions: partitions)
    }

    private static func parseState(_ raw: Any?) -> String {
        if let value = raw as? String { return value }
        if let values = raw as? [String] { return values.joined(separator: "|") }
        if let values = raw as? [Any] {
            return values.compactMap { $0 as? String }.joined(separator: "|")
        }
        return ""
    }

    private static func anyToString(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    private static func anyToInt(_ value: Any?) -> Int? {
        switch value {
        case let i as Int:
            return i
        case let i64 as Int64:
            return Int(i64)
        case let d as Double:
            return Int(d)
        case let n as NSNumber:
            return n.intValue
        case let s as String:
            return Int(s)
        default:
            return nil
        }
    }

    private static func parseNumeric(_ value: Any?) -> Int? {
        if let number = anyToInt(value) {
            return number
        }

        if let object = value as? [String: Any] {
            if let set = object["set"] as? Bool, set == false { return nil }
            if let infinite = object["infinite"] as? Bool, infinite == true { return nil }
            return anyToInt(object["number"])
        }

        return nil
    }

    private static func inferredAllocatedMemory(totalMB: Int?, allocatedMB: Int?, freeMB: Int?) -> Int? {
        if let allocatedMB {
            return max(0, allocatedMB)
        }

        if let totalMB, let freeMB {
            let boundedFree = max(0, min(freeMB, totalMB))
            return max(0, totalMB - boundedFree)
        }

        return nil
    }

    private static func nested(_ source: [String: Any], _ keys: [String]) -> Any? {
        var current: Any = source
        for key in keys {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func sanitizeEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(null)" { return nil }
        return trimmed
    }
}
