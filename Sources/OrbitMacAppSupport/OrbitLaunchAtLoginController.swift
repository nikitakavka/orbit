import AppKit
import Combine
import Foundation
import ServiceManagement

public enum OrbitLaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol OrbitLoginItemServicing: AnyObject {
    var status: OrbitLaunchAtLoginStatus { get }
    func register() throws
    func unregister() async throws
}

@MainActor
private final class OrbitSystemLoginItemService: OrbitLoginItemServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: OrbitLaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }
}

public enum OrbitApplicationLocation {
    public static func isInstalledInApplications(
        appURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard appURL.pathExtension.lowercased() == "app" else { return false }

        let normalizedAppPath = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true)
        ]

        return applicationDirectories.contains { directory in
            let normalizedDirectoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
            return normalizedAppPath.hasPrefix(normalizedDirectoryPath + "/")
        }
    }
}

@MainActor
public final class OrbitLaunchAtLoginController: ObservableObject {
    @Published public private(set) var status: OrbitLaunchAtLoginStatus
    @Published public private(set) var isChanging = false
    @Published public private(set) var errorMessage: String?

    public let isInstalledInApplications: Bool

    private let service: OrbitLoginItemServicing

    public convenience init(
        appURL: URL = Bundle.main.bundleURL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.init(
            service: OrbitSystemLoginItemService(),
            appURL: appURL,
            homeDirectoryURL: homeDirectoryURL
        )
    }

    init(
        service: OrbitLoginItemServicing,
        appURL: URL,
        homeDirectoryURL: URL
    ) {
        self.service = service
        self.status = service.status
        self.isInstalledInApplications = OrbitApplicationLocation.isInstalledInApplications(
            appURL: appURL,
            homeDirectoryURL: homeDirectoryURL
        )
    }

    public var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    public var canChangeRegistration: Bool {
        isInstalledInApplications && !isChanging
    }

    public var statusTitle: String {
        if !isInstalledInApplications {
            return "Move Orbit to Applications first"
        }

        switch status {
        case .notRegistered:
            return "Off"
        case .enabled:
            return "On"
        case .requiresApproval:
            return "Waiting for macOS approval"
        case .notFound:
            return "Unavailable"
        }
    }

    public var statusHint: String {
        if let errorMessage {
            return errorMessage
        }

        if !isInstalledInApplications {
            return "Launch-at-login should only be enabled after Orbit.app has been moved to /Applications or ~/Applications."
        }

        switch status {
        case .notRegistered:
            return "Orbit will remain off after you log out or restart your Mac."
        case .enabled:
            return "Orbit will start quietly in the menu bar when you log in."
        case .requiresApproval:
            return "Enable Orbit in System Settings → General → Login Items."
        case .notFound:
            return "macOS could not find Orbit's login item registration."
        }
    }

    public func refresh() {
        status = service.status
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        guard isInstalledInApplications else {
            errorMessage = "Move Orbit.app to Applications, reopen it there, and then enable launch at login."
            return
        }

        isChanging = true
        errorMessage = nil
        defer {
            status = service.status
            isChanging = false
        }

        do {
            if enabled {
                switch service.status {
                case .notRegistered, .notFound:
                    try service.register()
                case .enabled, .requiresApproval:
                    break
                }
            } else if service.status != .notRegistered {
                try await service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func openSystemLoginItemsSettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.users?LoginItems"
        ].compactMap(URL.init(string:))

        return candidates.contains { NSWorkspace.shared.open($0) }
    }
}
