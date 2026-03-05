import Foundation

enum OrbitArrayTaskIDResolver {
    static func token(fromJobID rawID: String, parentJobID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix(parentJobID + "_") {
            let token = String(trimmed.dropFirst(parentJobID.count + 1))
            return token.isEmpty ? nil : token
        }

        if trimmed.hasPrefix(parentJobID + "[") && trimmed.hasSuffix("]") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: parentJobID.count + 1)
            let end = trimmed.index(before: trimmed.endIndex)
            let token = String(trimmed[start..<end])
            return token.isEmpty ? nil : token
        }

        if trimmed.hasPrefix(parentJobID + ".") {
            let token = String(trimmed.dropFirst(parentJobID.count + 1))
            return token.isEmpty ? nil : token
        }

        return nil
    }

    static func int(fromJobID rawID: String, parentJobID: String) -> Int? {
        token(fromJobID: rawID, parentJobID: parentJobID).flatMap(Int.init)
    }
}
