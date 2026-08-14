import AppKit
import SwiftUI
import OrbitCore
import OrbitMacAppSupport

@MainActor
final class OrbitMenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: OrbitMenuBarRuntime?
    private var viewModel: OrbitMenuBarViewModel?

    private var statusItem: NSStatusItem?
    private var statusIconTimer: Timer?
    private var terminationTask: Task<Void, Never>?
    private var isPreparingToTerminate = false
    private let statusIconAnimationStartedAt = ProcessInfo.processInfo.systemUptime
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var settingsViewModel: OrbitSettingsViewModel?
    private let launchAtLoginController: OrbitLaunchAtLoginController
    private let updaterController: OrbitUpdaterController
    private let presentation: OrbitMenuBarPresentationModel

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()

        let addClusterItem = NSMenuItem(title: "Add Cluster…", action: #selector(addClusterFromStatusMenu(_:)), keyEquivalent: "")
        addClusterItem.target = self
        menu.addItem(addClusterItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromStatusMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesFromStatusMenu(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = 1001
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Orbit", action: #selector(quitFromStatusMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }()

    override init() {
        let updaterController = OrbitUpdaterController()
        self.launchAtLoginController = OrbitLaunchAtLoginController()
        self.updaterController = updaterController
        self.presentation = OrbitMenuBarPresentationModel(updaterController: updaterController)
        super.init()

        updaterController.onRequestPresentation = { [weak self] in
            self?.showPopoverIfPossible()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let runtime = try OrbitMenuBarRuntime.make()
            self.runtime = runtime
            self.viewModel = OrbitMenuBarViewModel(service: runtime.service)
        } catch {
            presentStartupFailureAndTerminate(error)
            return
        }

        guard let viewModel else { return }

        configurePopover(viewModel: viewModel)
        configureStatusItem()

        viewModel.start()
        maybeShowOnboardingIfNeeded()

        if CommandLine.arguments.contains("--check-for-updates") ||
            CommandLine.arguments.contains("--test-automatic-update") {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 750_000_000)
                if CommandLine.arguments.contains("--test-automatic-update") {
                    self?.updaterController.checkForUpdatesForIntegrationTesting()
                } else {
                    self?.updaterController.checkForUpdates()
                }
            }
        } else if let delay = delayedUpdateCheckSeconds() {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.updaterController.checkForUpdates()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }
        guard !isPreparingToTerminate else { return .terminateLater }

        isPreparingToTerminate = true
        statusIconTimer?.invalidate()
        statusIconTimer = nil

        terminationTask = Task {
            await viewModel.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusIconTimer?.invalidate()
        statusIconTimer = nil
        if !isPreparingToTerminate {
            viewModel?.stop()
        }
    }

    private func delayedUpdateCheckSeconds() -> Double? {
        let prefix = "--check-for-updates-after="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
              let seconds = Double(argument.dropFirst(prefix.count)),
              seconds >= 0 else {
            return nil
        }
        return seconds
    }

    private func configurePopover(viewModel: OrbitMenuBarViewModel) {
        popover.behavior = .transient
        popover.animates = false

        let hostingController = NSHostingController(
            rootView: OrbitPopoverView(
                viewModel: viewModel,
                presentation: presentation,
                onOpenSettings: { [weak self] in
                    self?.openSettingsWindow()
                }
            )
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
        updateStatusBarIcon()
        startStatusBarIconAnimationIfNeeded()
    }

    private func startStatusBarIconAnimationIfNeeded() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let timer = Timer(
            timeInterval: 1.0 / OrbitStatusBarIcon.framesPerSecond,
            target: self,
            selector: #selector(updateStatusBarIconFrame(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        statusIconTimer = timer
    }

    private func updateStatusBarIcon() {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - statusIconAnimationStartedAt)
        let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0
            : elapsed.truncatingRemainder(dividingBy: OrbitStatusBarIcon.animationDuration)
                / OrbitStatusBarIcon.animationDuration
        statusItem?.button?.image = OrbitStatusBarIcon.image(progress: progress)
    }

    @objc private func updateStatusBarIconFrame(_ timer: Timer) {
        updateStatusBarIcon()
    }

    private func openSettingsWindow() {
        popover.performClose(nil)

        guard let runtime else { return }

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            settingsViewModel?.reload()
            return
        }

        let vm = OrbitSettingsViewModel(
            service: runtime.service,
            launchAtLoginController: launchAtLoginController,
            updaterController: updaterController
        )
        vm.reload()

        let root = OrbitSettingsView(viewModel: vm)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Orbit Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1020, height: 720))
        window.center()

        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        settingsWindow = window
        settingsViewModel = vm
    }

    private func maybeShowOnboardingIfNeeded() {
        guard let runtime else { return }

        let profiles = (try? runtime.service.listProfiles()) ?? []
        if profiles.isEmpty {
            guard !OrbitOnboardingViewModel.isCompleted() else { return }
            showOnboardingInPopover(startAtCluster: false)
        } else {
            guard !OrbitOnboardingViewModel.isCurrentSetupCompleted() else { return }
            showOnboardingInPopover(
                startAtCluster: false,
                setupMode: .existingConfiguration,
                existingProfile: profiles.first
            )
        }
    }

    private func showOnboardingInPopover(
        startAtCluster: Bool,
        setupMode: OrbitOnboardingViewModel.SetupMode = .full,
        existingProfile: ClusterProfile? = nil
    ) {
        guard let runtime else { return }

        if let existing = presentation.onboardingViewModel {
            if startAtCluster && !existing.isExistingConfigurationSetup {
                existing.step = .cluster
            }
            showPopoverIfPossible()
            return
        }

        let launchStep = OrbitOnboardingViewModel.initialStepForLaunch()
        let initialStep: OrbitOnboardingViewModel.Step
        if startAtCluster {
            initialStep = .cluster
        } else if case .existingConfiguration = setupMode {
            initialStep = .startup
        } else {
            initialStep = launchStep
        }

        let vm = OrbitOnboardingViewModel(
            service: runtime.service,
            launchAtLoginController: launchAtLoginController,
            setupMode: setupMode,
            existingProfile: existingProfile,
            onFinish: { [weak self] in
                guard let self else { return }
                self.presentation.onboardingViewModel = nil
                self.viewModel?.refreshNow()
            },
            startAt: initialStep
        )

        presentation.onboardingViewModel = vm
        showPopoverIfPossible()
    }

    private func showPopoverIfPossible() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func presentStartupFailureAndTerminate(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Orbit failed to start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu(using: button)
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func showStatusMenu(using button: NSStatusBarButton) {
        popover.performClose(nil)

        guard let statusItem else { return }
        statusMenu.item(withTag: 1001)?.isEnabled = updaterController.canCheckForUpdates
        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func addClusterFromStatusMenu(_ sender: Any?) {
        showOnboardingInPopover(startAtCluster: true)
    }

    @objc private func openSettingsFromStatusMenu(_ sender: Any?) {
        openSettingsWindow()
    }

    @objc private func checkForUpdatesFromStatusMenu(_ sender: Any?) {
        updaterController.checkForUpdates()
    }

    @objc private func quitFromStatusMenu(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }
}
