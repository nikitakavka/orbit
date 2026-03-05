import Foundation

public enum CommandGuardError: Error, LocalizedError {
    case forbiddenOperator(String)
    case commandNotAllowlisted(String)

    public var errorDescription: String? {
        switch self {
        case .forbiddenOperator(let op):
            return "Command rejected: forbidden shell operator detected (\(op))"
        case .commandNotAllowlisted(let command):
            return "Command rejected: not in Orbit allowlist: \(command)"
        }
    }
}

public enum CommandGuard {
    private static let forbiddenOperators = ["&&", "||", ";", "|", ">>", ">", "$("]

    private static let allowlistPatterns = OrbitCommandCatalog.allowlistRegexPatterns

    public static func validate(_ command: String) throws {
        for op in forbiddenOperators {
            if command.contains(op) {
                throw CommandGuardError.forbiddenOperator(op)
            }
        }

        let allowed = allowlistPatterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }

        if !allowed {
            throw CommandGuardError.commandNotAllowlisted(command)
        }
    }
}
