import AppKit
import SwiftUI
import OrbitCore

@MainActor
final class OrbitUICaptureRunner: NSObject, NSApplicationDelegate {
    private let outputDirectory: URL
    private let runtime: OrbitMenuBarRuntime
    private let viewModel: OrbitMenuBarViewModel
    private let presentation = OrbitMenuBarPresentationModel()

    private let captureScale: CGFloat
    private let initialDelayMilliseconds: UInt64

    private var window: NSWindow?
    private(set) var exitCode: Int32 = 0

    init(outputDirectory: URL) throws {
        self.outputDirectory = outputDirectory
        self.runtime = try OrbitMenuBarRuntime.make()
        self.viewModel = OrbitMenuBarViewModel(service: runtime.service)

        let env = ProcessInfo.processInfo.environment
        let scaleRaw = Double(env["ORBIT_UI_CAPTURE_SCALE"] ?? "1") ?? 1
        self.captureScale = CGFloat(max(1.0, scaleRaw))

        let delayRaw = Int(env["ORBIT_UI_CAPTURE_INITIAL_DELAY_MS"] ?? "0") ?? 0
        self.initialDelayMilliseconds = UInt64(max(0, delayRaw))

        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = OrbitPopoverView(
            viewModel: viewModel,
            presentation: presentation,
            onOpenSettings: {}
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: hosting)
        window.title = "Orbit UI Capture"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        viewModel.start()

        Task { await runCaptureSequence() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stop()
    }

    private func runCaptureSequence() async {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            if initialDelayMilliseconds > 0 {
                try await pause(milliseconds: initialDelayMilliseconds)
            }

            _ = await waitUntil(timeoutSeconds: 12) { !self.viewModel.statuses.isEmpty }
            try await pause(milliseconds: 250)
            try capture(name: "01-default")

            if let firstArray = viewModel.selectedArrayGroups.first {
                viewModel.toggleArrayExpansion(parentJobID: firstArray.parentJobID)
                try await pause(milliseconds: 250)
            }
            try capture(name: "02-array-expanded")

            if !viewModel.isClusterLoadExpanded {
                viewModel.toggleClusterLoadExpansion()
            }
            _ = await waitUntil(timeoutSeconds: 8) {
                !self.viewModel.selectedNodeRows.isEmpty || !self.viewModel.isLoadingNodeInventory
            }
            try await pause(milliseconds: 300)
            try capture(name: "03-nodes-expanded")
        } catch {
            exitCode = 1
            fputs("orbit-menubar ui capture failed: \(error.localizedDescription)\n", stderr)
        }

        await runtime.service.shutdown()
        NSApplication.shared.terminate(nil)
    }

    private func capture(name: String) throws {
        let snapshot = OrbitPopoverView(
            viewModel: viewModel,
            presentation: presentation,
            onOpenSettings: {}
        )

        let renderer = ImageRenderer(content: snapshot)
        let baseScale = max(1.0, window?.backingScaleFactor ?? 2.0)
        renderer.scale = baseScale * captureScale

        guard let cgImage = renderer.cgImage else {
            throw NSError(domain: "OrbitUICapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "ImageRenderer failed to produce image"])
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "OrbitUICapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }

        let url = outputDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("saved \(url.path)")
    }

    private func pause(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private func waitUntil(timeoutSeconds: Int, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let intervalNanos: UInt64 = 200_000_000
        let attempts = max(1, timeoutSeconds * 5)

        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanos)
        }

        return condition()
    }
}
