import AppKit
import SwiftUI
import OrbitCore

@MainActor
final class OrbitMenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: OrbitMenuBarRuntime?
    private var viewModel: OrbitMenuBarViewModel?

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var settingsViewModel: OrbitSettingsViewModel?
    private let presentation = OrbitMenuBarPresentationModel()

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()

        let addClusterItem = NSMenuItem(title: "Add Cluster…", action: #selector(addClusterFromStatusMenu(_:)), keyEquivalent: "")
        addClusterItem.target = self
        menu.addItem(addClusterItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromStatusMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Orbit", action: #selector(quitFromStatusMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }()

    override init() {
        super.init()
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

        guard let runtime, let viewModel else { return }

        configurePopover(viewModel: viewModel)
        configureStatusItem()

        if runtime.notificationsEnabled {
            Task {
                _ = await UserNotificationEngine.requestAuthorization()
            }
        }

        viewModel.start()
        maybeShowOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.stop()
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
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(3.0)

            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: CGFloat(-25.0 * .pi / 180.0))
            context.strokeEllipse(in: CGRect(x: -10.2, y: -4.9, width: 20.4, height: 9.8))
            context.restoreGState()

            context.fillEllipse(in: CGRect(x: rect.midX - 3.8, y: rect.midY - 3.8, width: 7.6, height: 7.6))
            return true
        }

        image.isTemplate = true
        image.size = size
        return image
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

        let vm = OrbitSettingsViewModel(service: runtime.service)
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
        guard !OrbitOnboardingViewModel.isCompleted() else { return }
        guard let runtime else { return }

        let profiles = (try? runtime.service.listProfiles()) ?? []
        guard profiles.isEmpty else {
            OrbitOnboardingViewModel.markCompleted()
            return
        }

        showOnboardingInPopover(startAtCluster: false)
    }

    private func showOnboardingInPopover(startAtCluster: Bool) {
        guard let runtime else { return }

        if let existing = presentation.onboardingViewModel {
            if startAtCluster {
                existing.step = .cluster
            }
            showPopoverIfPossible()
            return
        }

        let vm = OrbitOnboardingViewModel(
            service: runtime.service,
            onFinish: { [weak self] in
                guard let self else { return }
                self.presentation.onboardingViewModel = nil
                self.viewModel?.refreshNow()
            },
            startAt: startAtCluster ? .cluster : .welcome
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

    @objc private func quitFromStatusMenu(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }
}
