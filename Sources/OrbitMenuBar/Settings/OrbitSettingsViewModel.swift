import Foundation
import AppKit
import UserNotifications
import OrbitCore

@MainActor
final class OrbitSettingsViewModel: ObservableObject {
    struct Draft {
        var id: UUID?
        var displayName: String = ""
        var hostname: String = ""
        var port: String = "22"
        var username: String = ""
        var sshKeyPath: String = ""
        var useSSHConfig: Bool = true
        var pollIntervalSeconds: String = "30"
        var extendedPollIntervalSeconds: String = "300"
        var fairshareEnabled: Bool = true
        var notifyOnComplete: Bool = true
        var notifyOnFail: Bool = true
        var notifyOnTimeWarningMinutes: String = "15"
        var grafanaURL: String = ""
        var isActive: Bool = true

        static func from(profile: ClusterProfile) -> Draft {
            Draft(
                id: profile.id,
                displayName: profile.displayName,
                hostname: profile.hostname,
                port: String(profile.port),
                username: profile.username,
                sshKeyPath: profile.sshKeyPath ?? "",
                useSSHConfig: profile.useSSHConfig,
                pollIntervalSeconds: String(profile.pollIntervalSeconds),
                extendedPollIntervalSeconds: String(profile.extendedPollIntervalSeconds),
                fairshareEnabled: profile.fairshareEnabled,
                notifyOnComplete: profile.notifyOnComplete,
                notifyOnFail: profile.notifyOnFail,
                notifyOnTimeWarningMinutes: String(profile.notifyOnTimeWarningMinutes),
                grafanaURL: profile.grafanaURL ?? "",
                isActive: profile.isActive
            )
        }

        var isValid: Bool {
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @Published private(set) var profiles: [ClusterProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var draft: Draft = Draft()
    @Published var isCreatingNew: Bool = false
    @Published var isBusy: Bool = false
    @Published var message: String?
    @Published var cpuHourRateText: String = "0.02"
    @Published var maxCommandOutputMBText: String = "500"
    @Published var auditEnabled: Bool = false

    @Published private(set) var systemNotificationStatusText: String = "Checking…"
    @Published private(set) var systemNotificationStatusHint: String = ""
    @Published private(set) var systemNotificationsAllowed: Bool = false

    @Published private(set) var auditEntries: [AuditLogEntry] = []
    @Published var auditLimit: Int = 120

    let commandTransparencyList: [String] = OrbitCommandCatalog.transparencyTemplates

    private let service: OrbitService

    init(service: OrbitService) {
        self.service = service
        self.cpuHourRateText = Self.rateText(for: OrbitAppSettings.cpuHourRate())
        self.maxCommandOutputMBText = String(OrbitAppSettings.maxCommandOutputMB())
        self.auditEnabled = OrbitAppSettings.auditEnabled()
        refreshSystemNotificationAuthorizationStatus()
    }

    func reload() {
        refreshSystemNotificationAuthorizationStatus()

        do {
            profiles = try service.listProfiles()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            if let selectedProfileID,
               profiles.contains(where: { $0.id == selectedProfileID }) {
                applySelectedProfileToDraft(selectedProfileID)
            } else {
                selectedProfileID = profiles.first?.id
                applySelectedProfileToDraft(selectedProfileID)
            }

            auditEnabled = OrbitAppSettings.auditEnabled()
            reloadAudit()
            cpuHourRateText = Self.rateText(for: OrbitAppSettings.cpuHourRate())
            maxCommandOutputMBText = String(OrbitAppSettings.maxCommandOutputMB())
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func selectProfile(_ id: UUID?) {
        selectedProfileID = id
        isCreatingNew = false
        applySelectedProfileToDraft(id)
    }

    func beginCreateProfile() {
        isCreatingNew = true
        selectedProfileID = nil
        draft = Draft()
        message = nil
    }

    func saveDraft() {
        guard draft.isValid else {
            message = "Display name, hostname, and username are required."
            return
        }

        let port = Int(draft.port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22

        guard let poll = Int(draft.pollIntervalSeconds.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "Poll interval must be an integer number of seconds."
            return
        }
        guard poll >= 1 else {
            message = "Poll interval must be at least 1 second."
            return
        }

        guard let extended = Int(draft.extendedPollIntervalSeconds.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "Extended poll interval must be an integer number of seconds."
            return
        }
        guard extended >= 1 else {
            message = "Extended poll interval must be at least 1 second."
            return
        }

        let warning = Int(draft.notifyOnTimeWarningMinutes.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 15

        do {
            let successMessage: String

            if let existingID = draft.id,
               let existing = profiles.first(where: { $0.id == existingID }),
               !isCreatingNew {
                var updated = existing
                updated.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.port = max(1, port)
                updated.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.sshKeyPath = nilIfEmpty(draft.sshKeyPath)
                updated.useSSHConfig = draft.useSSHConfig
                updated.pollIntervalSeconds = poll
                updated.extendedPollIntervalSeconds = extended
                updated.fairshareEnabled = draft.fairshareEnabled
                updated.notifyOnComplete = draft.notifyOnComplete
                updated.notifyOnFail = draft.notifyOnFail
                updated.notifyOnTimeWarningMinutes = max(0, warning)
                updated.grafanaURL = nilIfEmpty(draft.grafanaURL)
                updated.isActive = draft.isActive

                try service.addProfile(updated)
                selectedProfileID = updated.id
                successMessage = "Profile updated."
            } else {
                let created = ClusterProfile(
                    displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    hostname: draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: max(1, port),
                    username: draft.username.trimmingCharacters(in: .whitespacesAndNewlines),
                    sshKeyPath: nilIfEmpty(draft.sshKeyPath),
                    useSSHConfig: draft.useSSHConfig,
                    outputMode: .unknown,
                    slurmVersion: nil,
                    pollIntervalSeconds: poll,
                    extendedPollIntervalSeconds: extended,
                    fairshareEnabled: draft.fairshareEnabled,
                    notifyOnComplete: draft.notifyOnComplete,
                    notifyOnFail: draft.notifyOnFail,
                    notifyOnTimeWarningMinutes: max(0, warning),
                    grafanaURL: nilIfEmpty(draft.grafanaURL),
                    isActive: draft.isActive
                )

                try service.addProfile(created)
                selectedProfileID = created.id
                isCreatingNew = false
                successMessage = "Profile created."
            }

            reload()
            message = successMessage
        } catch {
            message = error.localizedDescription
        }
    }

    func deleteSelectedProfile() {
        guard let selectedProfileID else {
            message = "No profile selected."
            return
        }

        do {
            try service.deleteProfile(id: selectedProfileID)
            self.selectedProfileID = nil
            self.isCreatingNew = false
            self.draft = Draft()
            reload()
            message = "Profile deleted."
        } catch {
            message = error.localizedDescription
        }
    }

    func testConnectionForSelectedProfile() {
        guard let selectedProfileID else {
            message = "Save profile first, then test connection."
            return
        }

        isBusy = true
        Task {
            defer {
                Task { @MainActor in self.isBusy = false }
            }

            do {
                let result = try await service.testConnection(identifier: selectedProfileID.uuidString)
                let text = "Connected · SLURM \(result.slurmVersionRaw) · \(result.outputMode.rawValue.uppercased()) mode · jobs=\(result.jobCount)"
                await MainActor.run {
                    self.message = text
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func saveCPUHourRate() {
        let trimmed = cpuHourRateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value >= 0 else {
            message = "CPU-hour rate must be a non-negative number."
            cpuHourRateText = Self.rateText(for: OrbitAppSettings.cpuHourRate())
            return
        }

        OrbitAppSettings.setCPUHourRate(value)
        cpuHourRateText = Self.rateText(for: OrbitAppSettings.cpuHourRate())
        message = "CPU-hour rate saved."
    }

    func saveMaxCommandOutputMB() {
        let trimmed = maxCommandOutputMBText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 1 else {
            message = "Max command output must be an integer >= 1 MB."
            maxCommandOutputMBText = String(OrbitAppSettings.maxCommandOutputMB())
            return
        }

        OrbitAppSettings.setMaxCommandOutputMB(value)
        maxCommandOutputMBText = String(OrbitAppSettings.maxCommandOutputMB())
        message = "Max command output cap saved."
    }

    func setAuditEnabled(_ enabled: Bool) {
        OrbitAppSettings.setAuditEnabled(enabled)
        auditEnabled = OrbitAppSettings.auditEnabled()
        if auditEnabled {
            reloadAudit()
            message = "Audit logging enabled."
        } else {
            auditEntries = []
            message = "Audit logging disabled."
        }
    }

    func reloadAudit() {
        guard auditEnabled else {
            auditEntries = []
            return
        }

        do {
            auditEntries = try service.recentAudit(limit: max(10, min(auditLimit, 500)))
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshSystemNotificationAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }

            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.systemNotificationsAllowed = true
                    self.systemNotificationStatusText = "Allowed"
                    self.systemNotificationStatusHint = "Orbit can deliver notifications on this Mac."
                case .denied:
                    self.systemNotificationsAllowed = false
                    self.systemNotificationStatusText = "Blocked"
                    self.systemNotificationStatusHint = "Enable Orbit in System Settings → Notifications."
                case .notDetermined:
                    self.systemNotificationsAllowed = false
                    self.systemNotificationStatusText = "Not requested"
                    self.systemNotificationStatusHint = "Orbit will request permission when notifications are first needed."
                @unknown default:
                    self.systemNotificationsAllowed = false
                    self.systemNotificationStatusText = "Unknown"
                    self.systemNotificationStatusHint = "Could not determine notification permission state."
                }
            }
        }
    }

    func openSystemNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ].compactMap(URL.init(string:))

        let opened = urls.contains { NSWorkspace.shared.open($0) }
        if !opened {
            message = "Could not open macOS Notification settings."
        }
    }

    private func applySelectedProfileToDraft(_ id: UUID?) {
        guard let id,
              let profile = profiles.first(where: { $0.id == id }) else {
            draft = Draft()
            return
        }

        draft = Draft.from(profile: profile)
    }

    private static func rateText(for value: Double) -> String {
        String(format: "%.3f", value)
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression)
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
