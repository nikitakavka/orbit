import Foundation
import AppKit
import Combine
import UserNotifications
import OrbitCore
import OrbitMacAppSupport

private func shortOnboardingErrorMessage(_ error: Error) -> String {
    var message = error.localizedDescription
    if let firstLine = message.split(separator: "\n").first {
        message = String(firstLine)
    }

    if message.count > 180 {
        message = String(message.prefix(180)) + "…"
    }

    return message
}

private struct NetworkPermissionRetryFailed: LocalizedError {
    let underlying: Error?

    var errorDescription: String? {
        var message = "Connection failed after retrying. If macOS showed a permission prompt, enable Orbit in System Settings → Privacy & Security → Local Network."
        if let underlying {
            let detail = shortOnboardingErrorMessage(underlying)
            if !detail.isEmpty { message += " Last error: \(detail)" }
        }
        return message
    }
}

@MainActor
final class OrbitOnboardingViewModel: ObservableObject {
    enum SetupMode {
        case full
        case existingConfiguration
    }

    enum Step: Int, CaseIterable {
        case welcome
        case startup
        case cluster
        case sshKey
        case networkPermission
        case testing
        case notifications
        case done
    }

    enum ConnectionStepID: String, CaseIterable, Hashable {
        case ssh
        case auth
        case slurm
        case queue

        var title: String {
            switch self {
            case .ssh: return "Opening SSH connection"
            case .auth: return "Authenticating with key"
            case .slurm: return "Checking SLURM availability"
            case .queue: return "Fetching your queue"
            }
        }
    }

    enum ConnectionStepState {
        case waiting
        case running
        case done
        case fail
    }

    struct ConnectionStepStatus {
        var state: ConnectionStepState
        var label: String
    }

    enum NotificationPermissionState {
        case checking
        case granted
        case denied
        case notDetermined
        case unknown

        var isGranted: Bool {
            if case .granted = self { return true }
            return false
        }

        var statusText: String {
            switch self {
            case .granted:
                return "Notifications are enabled"
            case .denied:
                return "Notifications are disabled for Orbit in System Settings"
            case .notDetermined:
                return "Notification permission has not been requested yet"
            case .checking:
                return "Checking notification permission…"
            case .unknown:
                return "Could not determine notification permission"
            }
        }
    }

    struct SSHKeyOption: Identifiable, Equatable {
        let path: String
        let isRecommended: Bool

        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }

        var displayPath: String {
            let home = NSHomeDirectory()
            guard path.hasPrefix(home) else { return path }
            return "~" + path.dropFirst(home.count)
        }
    }

    @Published var step: Step {
        didSet {
            highestReachedStepRaw = max(highestReachedStepRaw, step.rawValue)
        }
    }
    @Published var hostname: String = ""
    @Published var port: String = "22"
    @Published var username: String

    @Published var discoveredKeys: [SSHKeyOption] = []
    @Published var selectedKeyPath: String?
    @Published var manualKeyPath: String = ""
    @Published var isManualPathEntryVisible: Bool = false
    @Published var keyScanSummary: String = "Scanned ~/.ssh · 0 keys found"

    @Published var formError: String?
    @Published var testErrorMessage: String?
    @Published var testHelpMessage: String?
    @Published var canContinueAfterTest: Bool = false
    @Published var isTestingConnection: Bool = false

    @Published private(set) var testStatuses: [ConnectionStepID: ConnectionStepStatus]
    @Published private(set) var notificationPermissionState: NotificationPermissionState = .checking
    @Published private(set) var isRequestingNotificationPermission = false

    private let service: OrbitService
    private let launchAtLoginController: OrbitLaunchAtLoginController
    private let setupMode: SetupMode
    private let existingProfile: ClusterProfile?
    private let onFinish: () -> Void
    private var appSupportObservers: Set<AnyCancellable> = []
    private var testTask: Task<Void, Never>?
    private var testedProfile: ClusterProfile?
    private var didPersistTestedProfile: Bool = false
    private var highestReachedStepRaw: Int
    private var hasShownNetworkPermissionGuidance = false

    private static let completedKey = "orbit.onboarding.completed"
    private static let resumeAtStartupKey = "orbit.onboarding.resumeAtStartup"
    private static let setupVersionKey = "orbit.onboarding.version"
    private static let currentSetupVersion = 2

    init(
        service: OrbitService,
        launchAtLoginController: OrbitLaunchAtLoginController,
        setupMode: SetupMode = .full,
        existingProfile: ClusterProfile? = nil,
        onFinish: @escaping () -> Void,
        startAt step: Step = .welcome
    ) {
        self.service = service
        self.launchAtLoginController = launchAtLoginController
        self.setupMode = setupMode
        self.existingProfile = existingProfile
        self.onFinish = onFinish
        self.step = step
        self.username = ""
        self.testStatuses = Self.defaultTestStatuses()
        self.highestReachedStepRaw = step.rawValue

        launchAtLoginController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &appSupportObservers)

        refreshNotificationPermissionStatus()
    }

    static func isCompleted() -> Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
        markCurrentSetupCompleted()
    }

    static func isCurrentSetupCompleted() -> Bool {
        UserDefaults.standard.integer(forKey: setupVersionKey) >= currentSetupVersion
    }

    static func markCurrentSetupCompleted() {
        UserDefaults.standard.set(currentSetupVersion, forKey: setupVersionKey)
        UserDefaults.standard.removeObject(forKey: resumeAtStartupKey)
    }

    static func initialStepForLaunch() -> Step {
        guard UserDefaults.standard.bool(forKey: resumeAtStartupKey) else {
            return .welcome
        }

        UserDefaults.standard.removeObject(forKey: resumeAtStartupKey)
        return .startup
    }

    var isExistingConfigurationSetup: Bool {
        if case .existingConfiguration = setupMode { return true }
        return false
    }

    var navigationSteps: [Step] {
        isExistingConfigurationSetup
            ? [.startup, .notifications, .done]
            : Step.allCases
    }

    func isStepReachableInNavigation(_ target: Step) -> Bool {
        navigationSteps.contains(target) && target.rawValue <= highestReachedStepRaw
    }

    func navigateToStep(_ target: Step) {
        guard isStepReachableInNavigation(target) else { return }

        if step == .testing, target != .testing, isTestingConnection {
            cancelTesting()
        }

        if target == .notifications {
            refreshNotificationPermissionStatus()
        }

        step = target
    }

    func continueFromWelcome() {
        step = .startup
        formError = nil
    }

    var isInstalledInApplications: Bool {
        launchAtLoginController.isInstalledInApplications
    }

    var launchAtLoginStatus: OrbitLaunchAtLoginStatus {
        launchAtLoginController.status
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginController.status == .enabled
    }

    var launchAtLoginRequiresApproval: Bool {
        launchAtLoginController.status == .requiresApproval
    }

    var isChangingLaunchAtLogin: Bool {
        launchAtLoginController.isChanging
    }

    var launchAtLoginErrorMessage: String? {
        launchAtLoginController.errorMessage
    }

    var installedApplicationDisplayPath: String {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let homeApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path

        if appURL.path.hasPrefix(homeApplicationsPath + "/") {
            return "~/Applications/\(appURL.lastPathComponent)"
        }
        return "/Applications/\(appURL.lastPathComponent)"
    }

    var isRunningFromDownloads: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path.lowercased()
        return path.contains("/downloads/") || path.contains("/apptranslocation/")
    }

    func refreshStartupStatus() {
        launchAtLoginController.refresh()
    }

    func enableLaunchAtLoginAndContinue() {
        guard isInstalledInApplications else { return }

        Task {
            await launchAtLoginController.setEnabled(true)
            if launchAtLoginController.status == .enabled {
                continueFromStartup()
            }
        }
    }

    func continueFromStartup() {
        step = isExistingConfigurationSetup ? .notifications : .cluster
        if step == .notifications {
            refreshNotificationPermissionStatus()
        }
    }

    func openSystemLoginItemsSettings() {
        _ = launchAtLoginController.openSystemLoginItemsSettings()
    }

    func quitAndShowInstallationFolders() {
        UserDefaults.standard.set(true, forKey: Self.resumeAtStartupKey)

        let appURL = Bundle.main.bundleURL
        let sourceDirectory: URL
        if appURL.path.lowercased().contains("/apptranslocation/") {
            sourceDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        } else {
            sourceDirectory = appURL.deletingLastPathComponent()
        }

        NSWorkspace.shared.open(sourceDirectory)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))

        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            NSApplication.shared.terminate(nil)
        }
    }

    func continueFromCluster() {
        guard validateClusterFields() else { return }
        scanLocalSSHKeys()
        step = .sshKey
    }

    func back() {
        switch step {
        case .welcome:
            return
        case .startup:
            if !isExistingConfigurationSetup {
                step = .welcome
            }
        case .cluster:
            step = .startup
        case .sshKey:
            step = .cluster
        case .networkPermission:
            step = .sshKey
        case .testing:
            cancelTesting()
            step = .sshKey
        case .notifications:
            step = isExistingConfigurationSetup ? .startup : .testing
        case .done:
            return
        }

        formError = nil
        testErrorMessage = nil
    }

    func skipOnboarding() {
        finish()
    }

    func chooseKey(path: String) {
        selectedKeyPath = path
        testErrorMessage = nil
    }

    func toggleManualPathEntry() {
        isManualPathEntryVisible.toggle()
    }

    func continueFromSSHKey() {
        guard validateClusterFields() else {
            testErrorMessage = formError
            return
        }

        guard resolvedSSHKeyPath != nil else {
            testErrorMessage = "Select an SSH key or enter one manually."
            return
        }

        testErrorMessage = nil
        step = .networkPermission
    }

    func startConnectionTest() {
        guard validateClusterFields() else {
            testErrorMessage = formError
            return
        }

        guard let sshKeyPath = resolvedSSHKeyPath else {
            testErrorMessage = "Select an SSH key or enter one manually."
            return
        }

        testTask?.cancel()
        resetTestState()
        didPersistTestedProfile = false
        step = .testing
        isTestingConnection = true

        let candidate = buildProfile(sshKeyPath: sshKeyPath)

        testTask = Task {
            await runConnectionTest(profile: candidate, selectedKeyPath: sshKeyPath)
        }
    }

    func continueAfterNetworkPermissionPrompt() {
        startConnectionTest()
    }

    func continueFromNotificationPermission() {
        step = .done
    }

    func skipNotificationPermissionStep() {
        step = .done
    }

    func requestNotificationPermission() {
        guard UserNotificationEngine.isAvailable else {
            notificationPermissionState = .unknown
            return
        }
        guard !isRequestingNotificationPermission else { return }
        isRequestingNotificationPermission = true

        Task {
            _ = await UserNotificationEngine.requestAuthorization()
            isRequestingNotificationPermission = false
            refreshNotificationPermissionStatus()
        }
    }

    func refreshNotificationPermissionStatus() {
        guard UserNotificationEngine.isAvailable else {
            notificationPermissionState = .unknown
            return
        }

        notificationPermissionState = .checking

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }

            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.notificationPermissionState = .granted
                case .denied:
                    self.notificationPermissionState = .denied
                case .notDetermined:
                    self.notificationPermissionState = .notDetermined
                @unknown default:
                    self.notificationPermissionState = .unknown
                }
            }
        }
    }

    func openSystemNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ].compactMap(URL.init(string:))

        _ = urls.contains { NSWorkspace.shared.open($0) }
        refreshNotificationPermissionStatus()
    }

    func continueAfterSuccessfulTest() {
        guard canContinueAfterTest else { return }

        if didPersistTestedProfile {
            step = .notifications
            refreshNotificationPermissionStatus()
            return
        }

        let profileToSave = testedProfile ?? buildProfile(sshKeyPath: resolvedSSHKeyPath ?? "")

        do {
            try service.addProfile(profileToSave)
            didPersistTestedProfile = true
            step = .notifications
            refreshNotificationPermissionStatus()
            formError = nil
            testErrorMessage = nil
        } catch {
            testErrorMessage = error.localizedDescription
            canContinueAfterTest = false
        }
    }

    func finishAndOpenOrbit() {
        finish()
    }

    func status(for id: ConnectionStepID) -> ConnectionStepStatus {
        testStatuses[id] ?? ConnectionStepStatus(state: .waiting, label: id.title)
    }

    var clusterDisplayLine: String {
        if isExistingConfigurationSetup, let existingProfile {
            return "\(existingProfile.username) @ \(existingProfile.displayName)"
        }
        return "\(resolvedUsername) @ \(hostname.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var clusterUser: String { resolvedUsername }
    var clusterHost: String { hostname.trimmingCharacters(in: .whitespacesAndNewlines) }

    deinit {
        testTask?.cancel()
    }

    private func validateClusterFields() -> Bool {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            formError = "Hostname is required."
            return false
        }

        let user = resolvedUsername
        guard !user.isEmpty else {
            formError = "Username is required."
            return false
        }

        let resolvedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        guard (1...65535).contains(resolvedPort) else {
            formError = "Port must be between 1 and 65535."
            return false
        }

        hostname = host
        username = user
        port = String(resolvedPort)
        formError = nil
        return true
    }

    private var resolvedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedSSHKeyPath: String? {
        if isManualPathEntryVisible {
            let manual = manualKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !manual.isEmpty { return NSString(string: manual).expandingTildeInPath }
        }

        if let selectedKeyPath {
            return selectedKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selectedKeyPath
        }

        return nil
    }

    private func scanLocalSSHKeys() {
        let paths = Self.discoverCandidateKeys()
        let recommended = Self.recommendedKey(in: paths)

        discoveredKeys = paths.map { path in
            SSHKeyOption(path: path, isRecommended: path == recommended)
        }

        if let selectedKeyPath, paths.contains(selectedKeyPath) {
            self.selectedKeyPath = selectedKeyPath
        } else {
            self.selectedKeyPath = recommended ?? paths.first
        }

        let count = paths.count
        keyScanSummary = "Scanned ~/.ssh · \(count) key\(count == 1 ? "" : "s") found"
    }

    private func runConnectionTest(profile: ClusterProfile, selectedKeyPath: String) async {
        let connection = SSHConnection(profile: profile)
        var activeStep: ConnectionStepID = .ssh

        do {
            activeStep = .ssh
            let showPermissionGuidance = !hasShownNetworkPermissionGuidance
            hasShownNetworkPermissionGuidance = true

            if showPermissionGuidance {
                setStep(.ssh, .running, label: "Waiting for macOS network permission…")
                testHelpMessage = "If macOS asks for network access, click Allow. Orbit will retry automatically."
            } else {
                setStep(.ssh, .running, label: "Opening SSH connection")
                testHelpMessage = nil
            }

            try await establishMasterWithPermissionRetry(connection, allowPermissionRetry: showPermissionGuidance)
            setStep(.ssh, .done, label: "SSH connection established")
            testHelpMessage = nil

            activeStep = .auth
            setStep(.auth, .running)
            let versionResult = try await connection.run(SlurmCommandBuilder.slurmVersionCommand)
            let versionRaw = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedVersion = SlurmVersion(parsing: versionRaw)
            if let parsedVersion, !parsedVersion.supportsJSON {
                throw OrbitServiceError.legacySlurmUnsupported
            }
            setStep(.auth, .done, label: "Authenticated with \(URL(fileURLWithPath: selectedKeyPath).lastPathComponent)")

            activeStep = .slurm
            setStep(.slurm, .running)
            _ = try await connection.run(SlurmCommandBuilder.partitionsCommand)
            let slurmLabel = versionRaw.isEmpty ? "SLURM detected" : "SLURM \(versionRaw) detected"
            setStep(.slurm, .done, label: slurmLabel)

            activeStep = .queue
            setStep(.queue, .running)
            let builder = try SlurmCommandBuilder(mode: .json, username: profile.username)
            let queueResult = try await connection.run(builder.squeueCommand)
            let jobCount = (try? JSONSlurmParser().parseJobs(queueResult.stdout, profileId: profile.id).count) ?? 0
            setStep(.queue, .done, label: "\(jobCount) jobs in your queue")

            var finalized = profile
            finalized.outputMode = .json
            finalized.slurmVersion = parsedVersion.map { "\($0.major).\($0.minor).\($0.patch)" } ?? (versionRaw.isEmpty ? nil : versionRaw)
            testedProfile = finalized
            canContinueAfterTest = true
            testErrorMessage = nil
        } catch {
            if Task.isCancelled {
                await connection.teardown()
                return
            }
            setStep(activeStep, .fail)
            canContinueAfterTest = false
            testHelpMessage = nil
            testErrorMessage = Self.userFacingError(error)
        }

        await connection.teardown()
        if !Task.isCancelled {
            isTestingConnection = false
        }
    }

    private func establishMasterWithPermissionRetry(_ connection: SSHConnection, allowPermissionRetry: Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        var lastError: Error?
        var didRetry = false

        repeat {
            do {
                try await connection.establishMaster()
                return
            } catch {
                if Task.isCancelled { throw error }
                lastError = error

                guard allowPermissionRetry, Self.shouldRetryForNetworkPermission(error), Date() < deadline else {
                    throw didRetry ? NetworkPermissionRetryFailed(underlying: lastError) : error
                }

                didRetry = true
                setStep(.ssh, .running, label: "Waiting for macOS permission… retrying")
                testHelpMessage = "Click Allow in the macOS prompt. If you already did, Orbit will retry in a moment."
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        } while Date() < deadline

        throw NetworkPermissionRetryFailed(underlying: lastError)
    }

    private func cancelTesting() {
        testTask?.cancel()
        testTask = nil
        isTestingConnection = false
        canContinueAfterTest = false
        testedProfile = nil
        didPersistTestedProfile = false
        resetTestState()
    }

    private func resetTestState() {
        testStatuses = Self.defaultTestStatuses()
        testErrorMessage = nil
        testHelpMessage = nil
        canContinueAfterTest = false
        testedProfile = nil
        didPersistTestedProfile = false
    }

    private func setStep(_ id: ConnectionStepID, _ state: ConnectionStepState, label: String? = nil) {
        var current = testStatuses[id] ?? ConnectionStepStatus(state: .waiting, label: id.title)
        current.state = state
        if let label {
            current.label = label
        }
        testStatuses[id] = current
    }

    private func buildProfile(sshKeyPath: String) -> ClusterProfile {
        ClusterProfile(
            displayName: hostname,
            hostname: hostname,
            port: Int(port) ?? 22,
            username: resolvedUsername,
            sshKeyPath: sshKeyPath,
            useSSHConfig: false,
            outputMode: .unknown,
            slurmVersion: nil,
            pollIntervalSeconds: 30,
            extendedPollIntervalSeconds: 300,
            fairshareEnabled: true,
            notifyOnComplete: true,
            notifyOnFail: true,
            notifyOnTimeWarningMinutes: 15,
            grafanaURL: nil,
            isActive: true
        )
    }

    private func finish() {
        if isExistingConfigurationSetup {
            Self.markCurrentSetupCompleted()
        } else {
            Self.markCompleted()
        }
        onFinish()
    }

    private static func discoverCandidateKeys() -> [String] {
        let sshDir = NSString(string: "~/.ssh").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sshDir) else {
            return []
        }

        let excluded = Set(["config", "known_hosts", "authorized_keys"])
        let standardNames = Set(["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"])

        let candidates = files.compactMap { fileName -> String? in
            guard !excluded.contains(fileName), !fileName.hasSuffix(".pub") else { return nil }

            let fullPath = (sshDir as NSString).appendingPathComponent(fileName)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }

            let hasPublicPair = FileManager.default.fileExists(atPath: fullPath + ".pub")
            let isStandardName = standardNames.contains(fileName)
            return (hasPublicPair || isStandardName) ? fullPath : nil
        }

        return candidates.sorted { lhs, rhs in
            let lhsScore = keySortScore(lhs)
            let rhsScore = keySortScore(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs < rhs
        }
    }

    private static func recommendedKey(in paths: [String]) -> String? {
        paths.first { $0.hasSuffix("/id_ed25519") }
            ?? paths.first { $0.hasSuffix("/id_rsa") }
            ?? paths.first
    }

    private static func keySortScore(_ path: String) -> Int {
        if path.hasSuffix("/id_ed25519") { return 0 }
        if path.hasSuffix("/id_rsa") { return 1 }
        if path.hasSuffix("/id_ecdsa") { return 2 }
        if path.hasSuffix("/id_dsa") { return 3 }
        return 10
    }

    private static func defaultTestStatuses() -> [ConnectionStepID: ConnectionStepStatus] {
        Dictionary(uniqueKeysWithValues: ConnectionStepID.allCases.map {
            ($0, ConnectionStepStatus(state: .waiting, label: $0.title))
        })
    }

    private static func shouldRetryForNetworkPermission(_ error: Error) -> Bool {
        if case ProcessExecutionError.timedOut = error { return true }

        if case SSHConnectionError.commandFailed(_, let code, let stderr) = error, code == 255 {
            let lower = stderr.lowercased()
            let definiteInputErrors = [
                "could not resolve hostname",
                "no such identity",
                "identity file",
                "bad permissions",
                "host key verification failed",
                "permission denied"
            ]
            if definiteInputErrors.contains(where: { lower.contains($0) }) {
                return false
            }
            return true
        }

        let message = error.localizedDescription.lowercased()
        let retryHints = [
            "operation not permitted",
            "connection timed out",
            "socket is not connected"
        ]

        return retryHints.contains { message.contains($0) }
    }

    private static func userFacingError(_ error: Error) -> String {
        if let permissionError = error as? NetworkPermissionRetryFailed {
            return permissionError.localizedDescription
        }

        if let orbitError = error as? OrbitServiceError {
            return orbitError.localizedDescription
        }

        return shortOnboardingErrorMessage(error)
    }
}
