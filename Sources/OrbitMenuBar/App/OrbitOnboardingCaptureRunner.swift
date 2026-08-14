import AppKit
import SwiftUI
import OrbitMacAppSupport

@MainActor
final class OrbitOnboardingCaptureRunner: NSObject, NSApplicationDelegate {
    private let outputURL: URL
    private let runtime: OrbitMenuBarRuntime
    private let launchAtLoginController: OrbitLaunchAtLoginController
    private var onboardingViewModel: OrbitOnboardingViewModel?
    private(set) var exitCode: Int32 = 0

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        self.runtime = try OrbitMenuBarRuntime.make()
        self.launchAtLoginController = OrbitLaunchAtLoginController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewModel = OrbitOnboardingViewModel(
            service: runtime.service,
            launchAtLoginController: launchAtLoginController,
            onFinish: {},
            startAt: .startup
        )
        onboardingViewModel = viewModel

        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            capture(viewModel: viewModel)
            await runtime.service.shutdown()
            NSApplication.shared.terminate(nil)
        }
    }

    private func capture(viewModel: OrbitOnboardingViewModel) {
        let snapshot = OrbitOnboardingView(viewModel: viewModel)
            .frame(width: 400, height: 650)

        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 2

        guard let cgImage = renderer.cgImage else {
            fail("ImageRenderer failed to render onboarding")
            return
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fail("Failed to encode onboarding PNG")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            print("saved \(outputURL.path)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        exitCode = 1
        fputs("onboarding capture failed: \(message)\n", stderr)
    }
}
