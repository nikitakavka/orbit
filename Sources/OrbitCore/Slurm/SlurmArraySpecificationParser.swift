import Foundation

enum SlurmArraySpecificationParser {
    private static let maximumParsedTaskIDs = 10_000_000
    private static let directiveRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?m)^\s*#SBATCH\s+(?:--array(?:=|\s+)|-a(?:=|\s*))([^\s#]+)"#
    )
    private static let submitLineRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:^|\s)(?:--array(?:=|\s+)|-a(?:=|\s*))([\"']?[0-9][0-9,:%-]*[\"']?)"#
    )

    static func taskCount(inBatchScript script: String) -> Int? {
        guard let specification = firstCapture(in: script, regex: directiveRegex) else {
            return nil
        }
        return taskCount(inSpecification: specification)
    }

    static func taskCount(inSubmitLine submitLine: String) -> Int? {
        guard let specification = firstCapture(in: submitLine, regex: submitLineRegex) else {
            return nil
        }
        return taskCount(inSpecification: specification)
    }

    static func taskCount(inSpecification rawSpecification: String) -> Int? {
        taskIDs(inSpecification: rawSpecification)?.count
    }

    static func taskIDs(inSpecification rawSpecification: String) -> IndexSet? {
        var specification = rawSpecification.trimmingCharacters(in: .whitespacesAndNewlines)
        if specification.count >= 2,
           let first = specification.first,
           let last = specification.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            specification.removeFirst()
            specification.removeLast()
        }
        specification = specification
            .split(separator: "%", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        guard !specification.isEmpty else { return nil }

        if specification.lowercased().hasPrefix("0x") {
            return taskIDs(inHexBitmap: specification)
        }

        var taskIDs = IndexSet()

        for rawComponent in specification.split(separator: ",", omittingEmptySubsequences: false) {
            let component = String(rawComponent).trimmingCharacters(in: .whitespaces)
            guard !component.isEmpty else { return nil }

            let rangeAndStep = component.split(separator: ":", maxSplits: 1).map(String.init)
            guard rangeAndStep.count <= 2 else { return nil }
            let step = rangeAndStep.count == 2 ? Int(rangeAndStep[1]) : 1
            guard let step, step > 0 else { return nil }

            let bounds = rangeAndStep[0].split(separator: "-", maxSplits: 1).map(String.init)
            if bounds.count == 1 {
                guard let taskID = Int(bounds[0]),
                      taskID >= 0,
                      taskID <= maximumParsedTaskIDs else { return nil }
                taskIDs.insert(taskID)
                continue
            }

            guard bounds.count == 2,
                  let lower = Int(bounds[0]),
                  let upper = Int(bounds[1]),
                  lower >= 0,
                  upper >= lower,
                  upper <= maximumParsedTaskIDs,
                  ((upper - lower) / step) + 1 <= maximumParsedTaskIDs else {
                return nil
            }

            if step == 1 {
                taskIDs.insert(integersIn: lower...upper)
            } else {
                var taskID = lower
                while taskID <= upper {
                    taskIDs.insert(taskID)
                    guard taskID <= Int.max - step else { break }
                    taskID += step
                }
            }
        }

        guard !taskIDs.isEmpty, taskIDs.count <= maximumParsedTaskIDs else { return nil }
        return taskIDs
    }

    private static func taskIDs(inHexBitmap rawBitmap: String) -> IndexSet? {
        let digits = rawBitmap.dropFirst(2)
        guard !digits.isEmpty,
              digits.count <= (maximumParsedTaskIDs / 4) + 1 else {
            return nil
        }

        var taskIDs = IndexSet()
        for (nibbleIndex, character) in digits.reversed().enumerated() {
            guard let nibble = character.hexDigitValue else { return nil }
            for bit in 0..<4 where (nibble & (1 << bit)) != 0 {
                let taskID = nibbleIndex * 4 + bit
                guard taskID <= maximumParsedTaskIDs else { return nil }
                taskIDs.insert(taskID)
            }
        }

        return taskIDs.isEmpty ? nil : taskIDs
    }

    private static func firstCapture(
        in text: String,
        regex: NSRegularExpression?
    ) -> String? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}
