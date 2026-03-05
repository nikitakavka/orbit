import Foundation
import AppKit

@MainActor
func runUICapture(outputPath: String?) async -> Int32 {
    let destination = outputPath ?? "artifacts/ui"
    let url = URL(fileURLWithPath: destination, isDirectory: true)

    do {
        let app = NSApplication.shared
        let runner = try OrbitUICaptureRunner(outputDirectory: url)
        app.delegate = runner
        app.setActivationPolicy(.regular)
        app.run()
        return runner.exitCode
    } catch {
        fputs("orbit-menubar ui capture failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

func runSmokeTest() async -> Int32 {
    do {
        let runtime = try OrbitMenuBarRuntime.make()
        let statuses = try await runtime.service.statusAll(refresh: false, activeOnly: false)

        await MainActor.run {
            let settingsVM = OrbitSettingsViewModel(service: runtime.service)
            settingsVM.reload()
            _ = settingsVM.auditEntries.count
        }

        print("orbit-menubar smoke test: ok (profiles=\(statuses.count))")
        await runtime.service.shutdown()
        return 0
    } catch {
        fputs("orbit-menubar smoke test failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

if let captureIndex = CommandLine.arguments.firstIndex(of: "--capture-ui") {
    let nextIndex = captureIndex + 1
    let outputPath: String?
    if nextIndex < CommandLine.arguments.count, !CommandLine.arguments[nextIndex].hasPrefix("--") {
        outputPath = CommandLine.arguments[nextIndex]
    } else {
        outputPath = nil
    }

    let code = await runUICapture(outputPath: outputPath)
    exit(code)
}

if CommandLine.arguments.contains("--smoke-test") {
    let code = await runSmokeTest()
    exit(code)
}

let app = NSApplication.shared
let delegate = OrbitMenuBarAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
