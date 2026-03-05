import Foundation

public struct SSHConfigDetails: Equatable {
    public let hostPattern: String
    public let hostName: String?
    public let user: String?
    public let port: Int?
    public let identityFile: String?
    public let proxyJump: String?
}

public struct SSHDetectionResult: Equatable {
    public let configMatch: SSHConfigDetails?
    public let workingKeys: [String]

    public var recommendedKey: String? {
        workingKeys.first
    }

    public var hasUsableAuth: Bool {
        configMatch != nil || !workingKeys.isEmpty
    }
}

public enum SSHKeyDetector {
    public static func detectSSHConfig(hostname: String, username: String) async -> SSHDetectionResult {
        if let configMatch = parseUserSSHConfig(hostname: hostname) {
            return SSHDetectionResult(configMatch: configMatch, workingKeys: [])
        }

        let candidates = discoverCandidateKeys()
        if candidates.isEmpty {
            return SSHDetectionResult(configMatch: nil, workingKeys: [])
        }

        var working: [String] = []
        for keyPath in candidates {
            let ok = await testKey(path: keyPath, username: username, hostname: hostname)
            if ok {
                working.append(keyPath)
            }
        }

        return SSHDetectionResult(configMatch: nil, workingKeys: working)
    }

    static func parseUserSSHConfig(hostname: String) -> SSHConfigDetails? {
        let configPath = NSString(string: "~/.ssh/config").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8)
        else {
            return nil
        }

        return parseConfig(content: content, hostname: hostname)
    }

    static func parseConfig(content: String, hostname: String) -> SSHConfigDetails? {
        struct HostBlock {
            var hostPattern: String = ""
            var hostName: String?
            var user: String?
            var port: Int?
            var identityFile: String?
            var proxyJump: String?
        }

        var current: HostBlock?
        var blocks: [HostBlock] = []

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "host" {
                if let current { blocks.append(current) }
                current = HostBlock(hostPattern: value)
                continue
            }

            guard current != nil else { continue }

            switch key {
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile": current?.identityFile = expandPath(value)
            case "proxyjump": current?.proxyJump = value
            default: break
            }
        }

        if let current { blocks.append(current) }

        guard let match = blocks.first(where: { hostMatches(pattern: $0.hostPattern, hostname: hostname) }) else {
            return nil
        }

        return SSHConfigDetails(
            hostPattern: match.hostPattern,
            hostName: match.hostName,
            user: match.user,
            port: match.port,
            identityFile: match.identityFile,
            proxyJump: match.proxyJump
        )
    }

    static func discoverCandidateKeys() -> [String] {
        let sshDir = NSString(string: "~/.ssh").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sshDir) else {
            return []
        }

        let excluded = Set(["config", "known_hosts", "authorized_keys"])
        let standardNames = Set(["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"])

        let all = files.filter { name in
            if excluded.contains(name) { return false }
            if name.hasSuffix(".pub") { return false }
            return true
        }

        return all.compactMap { name in
            let fullPath = (sshDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }

            let hasPubPair = FileManager.default.fileExists(atPath: fullPath + ".pub")
            let isStandard = standardNames.contains(name)
            return (hasPubPair || isStandard) ? fullPath : nil
        }
    }

    private static func testKey(path: String, username: String, hostname: String) async -> Bool {
        let args = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-i", path,
            "\(username)@\(hostname)",
            "echo ok"
        ]

        guard let result = try? await CommandExecutor.run(
            executable: "/usr/bin/ssh",
            arguments: args,
            timeoutSeconds: 10
        ) else {
            return false
        }

        return result.exitCode == 0
    }

    private static func hostMatches(pattern: String, hostname: String) -> Bool {
        let patterns = pattern.split(separator: " ").map(String.init)
        return patterns.contains { one in
            let regex = "^" + NSRegularExpression.escapedPattern(for: one)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
            return hostname.range(of: regex, options: .regularExpression) != nil
        }
    }

    private static func expandPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }
}
