import Foundation

extension OrbitMenuBarViewModel {
    func normalizedState(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "UNKNOWN" }
        return trimmed.uppercased().replacingOccurrences(of: "|", with: "/")
    }

    func severityForNodeState(_ state: String) -> NodeLoadRow.Severity {
        if state.contains("DOWN") || state.contains("FAIL") || state.contains("INVAL") {
            return .critical
        }
        if state.contains("DRAIN") || state.contains("MAINT") || state.contains("RESV") || state.contains("RESERVED") {
            return .warning
        }
        if state.contains("IDLE") || state.contains("ALLOC") || state.contains("MIX") || state.contains("COMPLET") {
            return .healthy
        }
        return .unknown
    }

    func parseGPUCount(_ gres: String?) -> Int? {
        guard let gres, !gres.isEmpty else { return nil }

        let chunks = gres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var total = 0

        for chunk in chunks {
            let lower = chunk.lowercased()
            guard lower.contains("gpu") else { continue }

            let sanitized = chunk.split(separator: "(", maxSplits: 1).first.map(String.init) ?? chunk

            if let eq = sanitized.firstIndex(of: "=") {
                let value = sanitized[sanitized.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let count = parseLeadingInteger(value), count > 0 {
                    total += count
                    continue
                }
            }

            for token in sanitized.split(separator: ":").reversed() {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if let count = parseLeadingInteger(trimmed), count > 0 {
                    total += count
                    break
                }
            }
        }

        return total > 0 ? total : nil
    }

    private func parseLeadingInteger(_ value: String) -> Int? {
        let prefix = value.prefix { $0.isNumber }
        guard !prefix.isEmpty else { return nil }
        return Int(prefix)
    }

    func formatAge(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        if safe < 60 { return "\(safe)s" }

        let minutes = safe / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        let rem = minutes % 60
        return "\(hours)h \(rem)m"
    }
}
