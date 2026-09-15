import Foundation

/// Parses the small, explicitly selected `sacct --parsable2` record set used by Orbit.
/// Keeping this separate from JSONSlurmParser prevents accounting polls from requiring
/// Slurm to construct its potentially very large JSON response in memory.
struct ParsableSacctParser {
    // This order must match SlurmCommandBuilder.accountingFields.
    private enum Field: Int {
        case jobIDRaw = 0
        case jobName
        case state
        case exitCode
        case elapsed
        case timeLimit
        case cpuTime
        case requestedCPUs
        case maxRSS
        case requestedMemory
        case start
        case end
    }

    private static let fieldCount = 12
    private let dateParser: DateFormatter

    init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        self.dateParser = formatter
    }

    func parseJobHistory(_ output: String, profileId: UUID) throws -> [JobHistorySnapshot] {
        let lines = output.split(whereSeparator: \.isNewline)
        if lines.isEmpty { return [] }

        var history: [JobHistorySnapshot] = []
        var sawMalformedRecord = false

        for line in lines {
            let columns = line.split(separator: "|", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let hasExpectedColumns = columns.count == Self.fieldCount
                || (columns.count == Self.fieldCount + 1 && columns.last?.isEmpty == true)
            guard hasExpectedColumns else {
                sawMalformedRecord = true
                continue
            }

            let id = columns[Field.jobIDRaw.rawValue]
            guard !id.isEmpty, !id.contains(".") else { continue }

            let arrayIdentity = parseArrayIdentity(id)
            let requestedCPUs = Int(columns[Field.requestedCPUs.rawValue]) ?? 0

            history.append(JobHistorySnapshot(
                id: id,
                profileId: profileId,
                name: nonempty(columns[Field.jobName.rawValue]) ?? "(unnamed)",
                state: parseState(columns[Field.state.rawValue]),
                exitCode: nonempty(columns[Field.exitCode.rawValue]),
                elapsed: parseDuration(columns[Field.elapsed.rawValue]) ?? 0,
                timeLimit: parseDuration(columns[Field.timeLimit.rawValue]),
                cpuTimeUsed: parseDuration(columns[Field.cpuTime.rawValue]) ?? 0,
                cpusRequested: requestedCPUs,
                maxRSS: parseMemoryKB(columns[Field.maxRSS.rawValue]),
                memoryRequested: parseRequestedMemoryKB(
                    columns[Field.requestedMemory.rawValue],
                    requestedCPUs: requestedCPUs
                ),
                startTime: parseDate(columns[Field.start.rawValue]),
                endTime: parseDate(columns[Field.end.rawValue]),
                arrayParentID: arrayIdentity?.parentID,
                arrayTaskID: arrayIdentity?.taskID,
                arrayTaskExpression: arrayIdentity?.expression
            ))
        }

        if history.isEmpty, sawMalformedRecord {
            throw SlurmParserError.invalidData("Malformed sacct parsable output")
        }
        return history
    }

    private func parseArrayIdentity(_ id: String) -> (parentID: String, taskID: Int?, expression: String?)? {
        guard let separator = id.firstIndex(of: "_") else { return nil }
        let parentID = String(id[..<separator])
        guard !parentID.isEmpty, parentID.allSatisfy(\.isNumber) else { return nil }

        var taskValue = String(id[id.index(after: separator)...])
        if taskValue.first == "[", taskValue.last == "]" {
            taskValue.removeFirst()
            taskValue.removeLast()
        }
        guard !taskValue.isEmpty else { return nil }

        if let taskID = Int(taskValue), taskID >= 0 {
            return (parentID, taskID, nil)
        }
        guard SlurmArraySpecificationParser.taskIDs(inSpecification: taskValue) != nil else {
            return nil
        }
        return (parentID, nil, taskValue)
    }

    private func parseState(_ rawValue: String) -> JobState {
        let firstToken = rawValue.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? rawValue
        return JobState.from(slurmState: firstToken.trimmingCharacters(in: CharacterSet(charactersIn: "+")))
    }

    private func parseDuration(_ rawValue: String) -> TimeInterval? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.uppercased() != "UNKNOWN",
              value.uppercased() != "UNLIMITED",
              value != "N/A" else { return nil }

        if let seconds = Double(value) { return seconds }

        let dayParts = value.split(separator: "-", maxSplits: 1).map(String.init)
        let days: Double
        let clock: String
        if dayParts.count == 2, let parsedDays = Double(dayParts[0]) {
            days = parsedDays
            clock = dayParts[1]
        } else {
            days = 0
            clock = value
        }

        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == clock.split(separator: ":").count else { return nil }

        let clockSeconds: Double
        switch parts.count {
        case 3: clockSeconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: clockSeconds = parts[0] * 60 + parts[1]
        case 1: clockSeconds = parts[0]
        default: return nil
        }
        return days * 86_400 + clockSeconds
    }

    private func parseRequestedMemoryKB(_ rawValue: String, requestedCPUs: Int) -> Int64? {
        var value = rawValue
        let isPerCPU = value.last?.lowercased() == "c"
        if isPerCPU || value.last?.lowercased() == "n" {
            value.removeLast()
        }
        guard let memory = parseMemoryKB(value) else { return nil }
        guard isPerCPU else { return memory }
        let cpuCount = Int64(max(1, requestedCPUs))
        guard memory <= Int64.max / cpuCount else { return nil }
        return memory * cpuCount
    }

    private func parseMemoryKB(_ rawValue: String) -> Int64? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !value.isEmpty, value != "N/A" else { return nil }

        let unit = value.last.map(String.init) ?? ""
        let multiplier: Double
        let number: String
        switch unit {
        case "K": multiplier = 1; number = String(value.dropLast())
        case "M": multiplier = 1024; number = String(value.dropLast())
        case "G": multiplier = 1024 * 1024; number = String(value.dropLast())
        case "T": multiplier = 1024 * 1024 * 1024; number = String(value.dropLast())
        case "P": multiplier = 1024 * 1024 * 1024 * 1024; number = String(value.dropLast())
        default: multiplier = 1; number = value
        }
        guard let amount = Double(number), amount >= 0 else { return nil }
        let kilobytes = amount * multiplier
        guard kilobytes.isFinite, kilobytes < Double(Int64.max) else { return nil }
        return Int64(kilobytes)
    }

    private func parseDate(_ rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.uppercased() != "UNKNOWN",
              value != "N/A" else { return nil }

        return dateParser.date(from: value)
    }

    private func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
