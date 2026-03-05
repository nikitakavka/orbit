import Foundation

public enum SlurmOutputMode: String, Codable {
    case json
    case legacy
    case unknown
}

public struct SlurmVersion: Comparable, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public static let minJsonVersion = SlurmVersion(major: 21, minor: 8, patch: 0)

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var supportsJSON: Bool {
        self >= Self.minJsonVersion
    }

    public init?(parsing string: String) {
        let pattern = #"(\d+)\.(\d+)(?:\.(\d+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: string.utf16.count)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              match.numberOfRanges >= 3,
              let majorRange = Range(match.range(at: 1), in: string),
              let minorRange = Range(match.range(at: 2), in: string)
        else {
            return nil
        }

        let major = Int(string[majorRange]) ?? 0
        let minor = Int(string[minorRange]) ?? 0

        var patch = 0
        if match.numberOfRanges > 3,
           let patchRange = Range(match.range(at: 3), in: string) {
            patch = Int(string[patchRange]) ?? 0
        }

        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: SlurmVersion, rhs: SlurmVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
