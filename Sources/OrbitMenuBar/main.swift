import Foundation
import AppKit
import OrbitMacAppSupport

@MainActor
func runLaunchAtLoginIntegrationTest() async -> Int32 {
    let controller = OrbitLaunchAtLoginController()

    guard controller.isInstalledInApplications else {
        fputs("launch-at-login test failed: copy the test app to Applications first\n", stderr)
        return 1
    }

    await controller.setEnabled(true)
    let registeredStatus = controller.status
    let registrationSucceeded = registeredStatus == .enabled || registeredStatus == .requiresApproval
    let registrationError = controller.errorMessage

    await controller.setEnabled(false)
    let cleanupSucceeded = controller.status == .notRegistered

    guard registrationSucceeded, cleanupSucceeded else {
        let reason = registrationError ?? controller.errorMessage ?? "unexpected ServiceManagement status"
        fputs("launch-at-login test failed: \(reason)\n", stderr)
        return 1
    }

    let statusText = registeredStatus == .enabled ? "enabled" : "registered; approval required"
    print("launch-at-login integration test: ok (\(statusText), cleanup=ok)")
    return 0
}

@MainActor
func runOnboardingStartupCapture(outputPath: String) async -> Int32 {
    do {
        let app = NSApplication.shared
        let runner = try OrbitOnboardingCaptureRunner(
            outputURL: URL(fileURLWithPath: outputPath)
        )
        app.delegate = runner
        app.setActivationPolicy(.prohibited)
        app.run()
        return runner.exitCode
    } catch {
        fputs("onboarding capture failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

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

if CommandLine.arguments.contains("--test-launch-at-login") {
    let code = await runLaunchAtLoginIntegrationTest()
    exit(code)
}

if let captureIndex = CommandLine.arguments.firstIndex(of: "--capture-onboarding-startup") {
    let pathIndex = captureIndex + 1
    guard pathIndex < CommandLine.arguments.count else {
        fputs("--capture-onboarding-startup requires an output PNG path\n", stderr)
        exit(2)
    }
    let code = await runOnboardingStartupCapture(outputPath: CommandLine.arguments[pathIndex])
    exit(code)
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
