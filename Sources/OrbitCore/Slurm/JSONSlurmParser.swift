import Foundation

public struct JSONSlurmParser: SlurmParser {
    private let isoParser: ISO8601DateFormatter
    private static let numericWithUnitRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(\d+(?:\.\d+)?)([KMGTP]?)$"#,
        options: .caseInsensitive
    )

    public init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoParser = formatter
    }

    public func parseJobs(_ output: String, profileId: UUID) throws -> [JobSnapshot] {
        guard let root = try decodeObject(output) else { throw SlurmParserError.invalidJSON }
        guard let jobs = root["jobs"] as? [[String: Any]] else { return [] }

        struct ParsedQueueJob {
            var snapshot: JobSnapshot
            let arrayRootID: Int?
            let arrayTaskID: Int?
            let arrayTaskString: String?
        }

        let parsed: [ParsedQueueJob] = jobs.compactMap { job in
            guard let id = anyToString(job["job_id"]) else { return nil }

            let state = parseState(job["job_state"])
            let name = anyToString(job["name"]) ?? "(unnamed)"
            let partition = anyToString(job["partition"]) ?? "unknown"
            let nodes = parseSlurmNumber(job["node_count"]) ?? anyToInt(job["node_count"]) ?? 0
            let cpus = parseCPUs(job)
            let nodeList = anyToString(job["nodes"]) ?? anyToString(nested(job, ["job_resources", "nodes", "list"]))
            let workingDirectory = anyToString(job["current_working_directory"])

            let submit = parseDate(job["submit_time"] ?? nested(job, ["time", "submission"]))
            let start = parseDate(job["start_time"] ?? nested(job, ["time", "start"]))

            var used = firstDuration([
                job["time_used"],
                nested(job, ["time", "elapsed"]),
                nested(job, ["time", "used"]),
                nested(job, ["time", "current"]),
                nested(job, ["time", "seconds"]),
                job["elapsed_time"],
                job["run_time"]
            ]) ?? 0

            if used <= 0,
               (state == .running || state == .completing),
               let start {
                used = max(0, Date().timeIntervalSince(start))
            }

            let nestedLimit = nested(job, ["time", "limit"])
            let topLevelLimit = job["time_limit"] ?? job["timelimit"]
            let rawLimit = nestedLimit ?? topLevelLimit
            let limit = parseLimit(rawLimit, assumeNumericMinutes: nestedLimit == nil && topLevelLimit != nil)
            let reason = normalizedReason(anyToString(job["state_reason"]) ?? anyToString(job["reason"]))
            let pendingReason = (state == .pending) ? reason : nil
            let memoryRequestedMB = parseRequestedMemoryMB(job: job, cpus: cpus)
            let gpuCount = parseGPUCount(job: job)

            let array = job["array"] as? [String: Any]
            let ownNumericJobID = Int(id)

            let rawArrayRootID = parseSlurmNumber(job["array_job_id"]) ?? anyToInt(array?["job_id"])
            let arrayRootID = normalizeArrayRootID(rawArrayRootID)

            let rawArrayTaskID = parseSlurmNumber(job["array_task_id"]) ?? parseSlurmNumber(array?["task_id"])
            let arrayTaskID = normalizeArrayTaskID(rawArrayTaskID)

            let rawArrayTaskString = anyToString(job["array_task_string"]) ?? anyToString(array?["task_string"])
            let arrayTaskString = normalizeArrayTaskString(rawArrayTaskString)
            let hasArrayTaskString = (arrayTaskString != nil)

            let taskCount = max(0, anyToInt(array?["task_count"]) ?? 0)
            let taskDone = max(0, anyToInt(array?["task_finished"]) ?? 0)

            let hasDistinctRoot = {
                guard let arrayRootID else { return false }
                if let ownNumericJobID {
                    return arrayRootID != ownNumericJobID
                }
                return true
            }()

            // Non-array jobs on some clusters may expose array_job_id=<job_id> and task_count=1.
            // Treat those as regular jobs unless we see explicit array semantics.
            let isArrayInitial = hasDistinctRoot || arrayTaskID != nil || hasArrayTaskString || taskCount > 1

            let normalizedArrayParentID = isArrayInitial ? arrayRootID.map(String.init) : nil
            let normalizedArrayTaskID = isArrayInitial ? arrayTaskID : nil
            let normalizedTaskDone = isArrayInitial ? taskDone : 0
            let normalizedTaskTotal = isArrayInitial ? taskCount : 0
            let normalizedTaskString = isArrayInitial ? arrayTaskString : nil

            let snapshot = JobSnapshot(
                id: id,
                profileId: profileId,
                name: name,
                state: state,
                partition: partition,
                nodes: nodes,
                cpus: cpus,
                nodeList: nodeList,
                memoryRequestedMB: memoryRequestedMB,
                gpuCount: gpuCount,
                workingDirectory: workingDirectory,
                timeUsed: used,
                timeLimit: limit,
                submitTime: submit,
                startTime: start,
                estimatedStartTime: nil,
                pendingReason: pendingReason,
                isArray: isArrayInitial,
                arrayParentID: normalizedArrayParentID,
                arrayTaskID: normalizedArrayTaskID,
                arrayTasksDone: normalizedTaskDone,
                arrayTasksTotal: normalizedTaskTotal,
                snapshotTime: Date()
            )

            return ParsedQueueJob(
                snapshot: snapshot,
                arrayRootID: isArrayInitial ? arrayRootID : nil,
                arrayTaskID: normalizedArrayTaskID,
                arrayTaskString: normalizedTaskString
            )
        }

        var snapshots = parsed.map { $0.snapshot }
        var arrayGroups: [Int: [Int]] = [:]

        for (index, item) in parsed.enumerated() {
            guard let arrayRootID = item.arrayRootID else { continue }
            arrayGroups[arrayRootID, default: []].append(index)
        }

        for (arrayRootID, indices) in arrayGroups {
            let rootID = String(arrayRootID)
            guard let parentIndex = indices.first(where: { snapshots[$0].id == rootID }) else { continue }

            // Child tasks (array elements) usually carry array_task_id and are RUNNING/PENDING.
            let runningCount = indices.filter {
                parsed[$0].arrayTaskID != nil && snapshots[$0].state == .running
            }.count

            let pendingStats = parsed[parentIndex].arrayTaskString.flatMap(parseArrayTaskStringStats)
            let pendingFromChildren = indices.filter {
                parsed[$0].arrayTaskID != nil && snapshots[$0].state == .pending
            }.count

            let runningTaskIDs = Set(indices.compactMap { parsed[$0].arrayTaskID })
            let pendingCountRaw = pendingStats?.count ?? pendingFromChildren
            let overlappingRunningCount = pendingStats.map { stats in
                runningTaskIDs.filter { stats.contains($0) }.count
            } ?? 0

            // Some clusters expose task strings that overlap with explicit running child rows.
            // Treat overlap as running, not pending, to avoid inflated totals for non-zero ranges.
            let pendingCount = max(0, pendingCountRaw - overlappingRunningCount)

            let activeObservedCount: Int
            if pendingStats != nil {
                activeObservedCount = pendingCount + runningTaskIDs.count
            } else {
                activeObservedCount = pendingCount + runningCount
            }

            var total = max(
                snapshots[parentIndex].arrayTasksTotal,
                activeObservedCount + max(0, snapshots[parentIndex].arrayTasksDone)
            )

            if let pendingStats {
                total = max(total, pendingStats.count)
            }
            total = max(total, pendingCount + runningCount)

            var done = max(0, total - pendingCount - runningCount)

            if snapshots[parentIndex].arrayTasksDone > 0 {
                done = max(done, snapshots[parentIndex].arrayTasksDone)
            }

            snapshots[parentIndex].isArray = true
            snapshots[parentIndex].arrayTasksTotal = total
            snapshots[parentIndex].arrayTasksDone = min(done, total)

            for index in indices where index != parentIndex {
                // Keep child tasks as regular rows; the parent row carries aggregate array progress.
                snapshots[index].isArray = false
                snapshots[index].arrayTasksTotal = 0
                snapshots[index].arrayTasksDone = 0
            }
        }

        return snapshots
    }

    public func parseJobHistory(_ output: String, profileId: UUID) throws -> [JobHistorySnapshot] {
        guard let root = try decodeObject(output) else { throw SlurmParserError.invalidJSON }
        guard let jobs = root["jobs"] as? [[String: Any]] else { return [] }

        return jobs.compactMap { job in
            guard let id = anyToString(job["job_id"]), !id.contains(".") else { return nil }

            let elapsed = parseDurationSeconds(job["elapsed"] ?? nested(job, ["time", "elapsed"])) ?? 0
            let limit = parseLimit(job["timelimit"] ?? nested(job, ["time", "limit"]))
            let cpuTimeUsed = parseDurationSeconds(job["cpu_time"] ?? nested(job, ["time", "total", "seconds"])) ?? 0
            let cpus = anyToInt(job["cpus_req"]) ?? anyToInt(job["cpus_requested"]) ?? 0

            return JobHistorySnapshot(
                id: id,
                profileId: profileId,
                name: anyToString(job["name"]) ?? "(unnamed)",
                state: parseState(job["state"] ?? job["job_state"]),
                exitCode: anyToString(job["exit_code"]),
                elapsed: elapsed,
                timeLimit: limit,
                cpuTimeUsed: cpuTimeUsed,
                cpusRequested: cpus,
                maxRSS: parseMemoryKB(job["max_rss"]),
                memoryRequested: parseMemoryKB(job["req_mem"]),
                startTime: parseDate(job["start_time"]),
                endTime: parseDate(job["end_time"])
            )
        }
    }

    public func parseEstimatedStart(_ output: String) -> Date? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "N/A", value != "Unknown" else { return nil }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]

        for format in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = format
            if let date = df.date(from: value) {
                return date
            }
        }

        if let epoch = Int(value) {
            return Date(timeIntervalSince1970: TimeInterval(epoch))
        }

        return nil
    }

    public func parseFairshare(_ output: String) -> Double? {
        guard let root = try? decodeObject(output),
              let shares = nested(root, ["shares", "shares"]) as? [[String: Any]]
        else {
            return nil
        }

        for item in shares {
            if let factor = nested(item, ["fairshare", "factor"]), let value = anyToDouble(factor) {
                return value
            }
            if let factor = item["fairshare_factor"], let value = anyToDouble(factor) {
                return value
            }
        }
        return nil
    }

    public func parseClusterLoad(_ output: String, profileId: UUID) throws -> ClusterLoad {
        guard let root = try decodeObject(output) else { throw SlurmParserError.invalidJSON }

        // Format A (common): { "nodes": [ ... ] }
        if let nodes = root["nodes"] as? [[String: Any]] {
            var totalCPUs = 0
            var allocatedCPUs = 0
            var totalNodes = 0
            var allocatedNodes = 0

            for node in nodes {
                let total = anyToInt(nested(node, ["cpus", "total"]) ?? node["cpus"])
                let alloc = anyToInt(nested(node, ["cpus", "allocated"]) ?? node["alloc_cpus"])

                guard let total, let alloc, total > 0 else { continue }
                totalNodes += 1
                totalCPUs += total
                allocatedCPUs += max(0, min(alloc, total))
                if alloc > 0 { allocatedNodes += 1 }
            }

            return ClusterLoad(
                profileId: profileId,
                totalCPUs: totalCPUs,
                allocatedCPUs: allocatedCPUs,
                totalNodes: totalNodes,
                allocatedNodes: allocatedNodes,
                fetchedAt: Date()
            )
        }

        // Format B (seen on some clusters): { "sinfo": [ { cpus: {...}, nodes: {...} } ] }
        if let sinfoRows = root["sinfo"] as? [[String: Any]] {
            var totalCPUs = 0
            var allocatedCPUs = 0
            var totalNodes = 0
            var allocatedNodes = 0

            for row in sinfoRows {
                let cpus = row["cpus"] as? [String: Any]
                let nodes = row["nodes"] as? [String: Any]

                guard let rowTotalCPUs = anyToInt(cpus?["total"]), rowTotalCPUs > 0 else { continue }
                let rowAllocatedCPUs = anyToInt(cpus?["allocated"]) ?? 0

                let rowTotalNodes = anyToInt(nodes?["total"]) ?? 0
                let rowAllocatedNodes = anyToInt(nodes?["allocated"]) ?? 0

                totalCPUs += rowTotalCPUs
                allocatedCPUs += max(0, min(rowAllocatedCPUs, rowTotalCPUs))
                totalNodes += max(0, rowTotalNodes)
                allocatedNodes += max(0, min(rowAllocatedNodes, rowTotalNodes))
            }

            return ClusterLoad(
                profileId: profileId,
                totalCPUs: totalCPUs,
                allocatedCPUs: allocatedCPUs,
                totalNodes: totalNodes,
                allocatedNodes: allocatedNodes,
                fetchedAt: Date()
            )
        }

        throw SlurmParserError.invalidData("Unsupported sinfo JSON shape")
    }

    private func decodeObject(_ output: String) throws -> [String: Any]? {
        let data = Data(output.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        return json as? [String: Any]
    }

    private func parseState(_ raw: Any?) -> JobState {
        if let state = raw as? String {
            return JobState.from(slurmState: state)
        }

        if let states = raw as? [String], let first = states.first {
            return JobState.from(slurmState: first)
        }

        if let states = raw as? [Any], let first = states.first as? String {
            return JobState.from(slurmState: first)
        }

        return .unknown
    }

    private func parseCPUs(_ job: [String: Any]) -> Int {
        if let value = parseSlurmNumber(job["cpus"]) ?? anyToInt(job["cpus"]) { return value }
        if let value = parseSlurmNumber(job["num_cpus"]) ?? anyToInt(job["num_cpus"]) { return value }
        if let value = parseSlurmNumber(nested(job, ["job_resources", "cpus"])) ?? anyToInt(nested(job, ["job_resources", "cpus"])) { return value }
        return 0
    }

    private func parseLimit(_ raw: Any?, assumeNumericMinutes: Bool = false) -> TimeInterval? {
        if let intValue = parseSlurmNumber(raw) ?? anyToInt(raw) {
            if intValue <= 0 { return nil }
            let seconds = assumeNumericMinutes ? intValue * 60 : intValue
            return TimeInterval(seconds)
        }

        if let str = anyToString(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            if str.uppercased() == "UNLIMITED" || str == "0" || str.uppercased() == "N/A" { return nil }
            return parseDurationSeconds(str)
        }

        return nil
    }

    private func firstDuration(_ values: [Any?]) -> TimeInterval? {
        for value in values {
            if let parsed = parseDurationSeconds(value) {
                return parsed
            }
        }
        return nil
    }

    private func parseDurationSeconds(_ raw: Any?) -> TimeInterval? {
        if let value = parseSlurmNumber(raw) ?? anyToInt(raw) {
            return TimeInterval(max(0, value))
        }

        guard let str = anyToString(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return nil
        }

        let upper = str.uppercased()
        if upper == "UNLIMITED" || upper == "N/A" || upper == "UNKNOWN" { return nil }

        if let intValue = Int(str) {
            return TimeInterval(max(0, intValue))
        }

        let daySplit = str.split(separator: "-", maxSplits: 1).map(String.init)
        let timePart: String
        var days = 0

        if daySplit.count == 2 {
            days = Int(daySplit[0]) ?? 0
            timePart = daySplit[1]
        } else {
            timePart = str
        }

        let parts = timePart.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }

        let total: Int
        switch parts.count {
        case 3:
            total = days * 24 * 3600 + parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2:
            total = days * 24 * 3600 + parts[0] * 60 + parts[1]
        case 1:
            total = days * 24 * 3600 + parts[0]
        default:
            return nil
        }

        return TimeInterval(max(0, total))
    }

    private func parseDate(_ raw: Any?) -> Date? {
        if let epoch = parseSlurmNumber(raw) ?? anyToInt(raw), epoch > 0 {
            return Date(timeIntervalSince1970: TimeInterval(epoch))
        }

        guard let text = anyToString(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        if let date = isoParser.date(from: text) {
            return date
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = fallback.date(from: text) {
            return date
        }

        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: text)
    }

    private func parseMemoryKB(_ raw: Any?) -> Int64? {
        if let value = anyToInt(raw) {
            return Int64(value)
        }

        guard let string = anyToString(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }

        if let value = Int64(string) {
            return value
        }

        guard let (number, unit) = parseNumberAndUnit(string) else {
            return nil
        }

        let multiplier: Double
        switch unit {
        case "T": multiplier = 1_073_741_824
        case "G": multiplier = 1_048_576
        case "M": multiplier = 1024
        case "K", "": multiplier = 1
        default: multiplier = 1
        }

        return Int64(number * multiplier)
    }

    private struct ArrayTaskSegment {
        let lower: Int
        let upper: Int
        let step: Int

        func contains(_ value: Int) -> Bool {
            guard value >= lower, value <= upper else { return false }
            return ((value - lower) % step) == 0
        }

        var count: Int {
            max(0, ((upper - lower) / step) + 1)
        }
    }

    private struct ArrayTaskStringStats {
        let count: Int
        let minID: Int?
        let maxID: Int?
        let segments: [ArrayTaskSegment]

        func contains(_ value: Int) -> Bool {
            segments.contains(where: { $0.contains(value) })
        }
    }

    private func normalizeArrayRootID(_ raw: Int?) -> Int? {
        guard let raw else { return nil }
        guard raw > 0 else { return nil }
        // Slurm may use NO_VAL (~0U) sentinels for missing array metadata.
        if raw >= 4_294_967_294 { return nil }
        return raw
    }

    private func normalizeArrayTaskID(_ raw: Int?) -> Int? {
        guard let raw else { return nil }
        guard raw >= 0 else { return nil }
        if raw >= 4_294_967_294 { return nil }
        return raw
    }

    private func normalizeArrayTaskString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        if upper == "N/A" || upper == "NONE" || upper == "UNKNOWN" {
            return nil
        }

        return trimmed
    }

    private func parseSlurmNumber(_ value: Any?) -> Int? {
        if let object = value as? [String: Any] {
            if let set = object["set"] as? Bool, set == false { return nil }
            if let infinite = object["infinite"] as? Bool, infinite == true { return nil }
            return anyToInt(object["number"])
        }

        return anyToInt(value)
    }

    private func parseArrayTaskStringStats(_ raw: String) -> ArrayTaskStringStats? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "%", maxSplits: 1)
            .first
            .map(String.init) ?? ""

        guard !cleaned.isEmpty else { return nil }

        var totalCount = 0
        var minID: Int?
        var maxID: Int?
        var segments: [ArrayTaskSegment] = []

        for token in cleaned.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !token.isEmpty else { continue }

            if token.contains("-") {
                let rangeParts = token.split(separator: "-", maxSplits: 1).map(String.init)
                guard rangeParts.count == 2 else { continue }

                let start = Int(rangeParts[0].trimmingCharacters(in: .whitespacesAndNewlines))

                let endAndStep = rangeParts[1].split(separator: ":", maxSplits: 1).map(String.init)
                let end = Int(endAndStep[0].trimmingCharacters(in: .whitespacesAndNewlines))
                let stepRaw = (endAndStep.count == 2) ? Int(endAndStep[1].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                let step = max(1, stepRaw ?? 1)

                guard let start, let end else { continue }

                let low = min(start, end)
                let high = max(start, end)
                let segment = ArrayTaskSegment(lower: low, upper: high, step: step)

                totalCount += segment.count
                minID = minID.map { min($0, low) } ?? low
                maxID = maxID.map { max($0, high) } ?? high
                segments.append(segment)
                continue
            }

            if let value = Int(token) {
                totalCount += 1
                minID = minID.map { min($0, value) } ?? value
                maxID = maxID.map { max($0, value) } ?? value
                segments.append(ArrayTaskSegment(lower: value, upper: value, step: 1))
            }
        }

        if totalCount == 0, minID == nil, maxID == nil {
            return nil
        }

        return ArrayTaskStringStats(count: totalCount, minID: minID, maxID: maxID, segments: segments)
    }

    private func normalizedReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        if upper == "NONE" || upper == "N/A" || upper == "UNKNOWN" {
            return nil
        }

        return trimmed
    }

    private func parseRequestedMemoryMB(job: [String: Any], cpus: Int) -> Int? {
        if let perNode = parseSlurmNumber(job["memory_per_node"]) ?? anyToInt(job["memory_per_node"]), perNode > 0 {
            return perNode
        }

        if let perCPU = parseSlurmNumber(job["memory_per_cpu"]) ?? anyToInt(job["memory_per_cpu"]), perCPU > 0 {
            let cpuCount = max(1, cpus)
            return perCPU * cpuCount
        }

        if let tres = anyToString(job["tres_alloc_str"]) ?? anyToString(job["tres_req_str"]),
           let mem = parseMemoryMBFromTRES(tres) {
            return mem
        }

        return nil
    }

    private func parseGPUCount(job: [String: Any]) -> Int? {
        let tres = anyToString(job["tres_alloc_str"]) ?? anyToString(job["tres_req_str"])
        guard let tres else { return nil }

        let parts = tres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for part in parts {
            let lower = part.lowercased()
            if lower.hasPrefix("gres/gpu") || lower.hasPrefix("gpu") {
                if let idx = part.firstIndex(of: "=") {
                    let value = String(part[part.index(after: idx)...])
                    if let parsed = Int(value), parsed > 0 {
                        return parsed
                    }
                }
            }
        }

        return nil
    }

    private func parseMemoryMBFromTRES(_ tres: String) -> Int? {
        let parts = tres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for part in parts {
            guard part.lowercased().hasPrefix("mem=") else { continue }
            let value = String(part.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }

            guard let (number, parsedUnit) = parseNumberAndUnit(value) else {
                continue
            }

            let unit = parsedUnit.isEmpty ? "M" : parsedUnit

            let mb: Double
            switch unit {
            case "T": mb = number * 1024.0 * 1024.0
            case "G": mb = number * 1024.0
            case "M", "": mb = number
            case "K": mb = number / 1024.0
            default: mb = number
            }

            return Int(mb.rounded())
        }

        return nil
    }

    private func parseNumberAndUnit(_ raw: String) -> (number: Double, unit: String)? {
        let range = NSRange(location: 0, length: raw.utf16.count)
        guard let regex = Self.numericWithUnitRegex,
              let match = regex.firstMatch(in: raw, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: raw),
              let number = Double(raw[numberRange])
        else {
            return nil
        }

        let unitRange = Range(match.range(at: 2), in: raw)
        let unit = unitRange.map { String(raw[$0]).uppercased() } ?? ""
        return (number, unit)
    }

    private func anyToString(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    private func anyToInt(_ value: Any?) -> Int? {
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

    private func anyToDouble(_ value: Any?) -> Double? {
        switch value {
        case let d as Double:
            return d
        case let n as NSNumber:
            return n.doubleValue
        case let s as String:
            return Double(s)
        default:
            return nil
        }
    }

    private func nested(_ source: [String: Any], _ keys: [String]) -> Any? {
        var current: Any = source
        for key in keys {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }
}
