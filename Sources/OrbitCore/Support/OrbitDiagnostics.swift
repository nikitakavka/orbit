import Foundation

enum OrbitDiagnostics {
    static func report(component: String, context: String, error: Error) {
        let line = "[Orbit][\(component)] \(context): \(error.localizedDescription)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

enum SlurmErrorClassifier {
    static func isAccountingStorageDisabled(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("accounting storage is disabled")
    }
}
