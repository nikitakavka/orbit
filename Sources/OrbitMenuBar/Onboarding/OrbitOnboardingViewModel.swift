import Foundation
import AppKit
import UserNotifications
import OrbitCore

@MainActor
final class OrbitOnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome
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
    @Published var canContinueAfterTest: Bool = false
    @Published var isTestingConnection: Bool = false

    @Published private(set) var testStatuses: [ConnectionStepID: ConnectionStepStatus]
    @Published private(set) var notificationPermissionState: NotificationPermissionState = .checking

    private let service: OrbitService
    private let onFinish: () -> Void
    private var testTask: Task<Void, Never>?
    private var testedProfile: ClusterProfile?
    private var didPersistTestedProfile: Bool = false
    private var highestReachedStepRaw: Int

    private static let completedKey = "orbit.onboarding.completed"

    init(service: OrbitService, onFinish: @escaping () -> Void, startAt step: Step = .welcome) {
        self.service = service
        self.onFinish = onFinish
        self.step = step
        self.username = ""
        self.testStatuses = Self.defaultTestStatuses()
        self.highestReachedStepRaw = step.rawValue
        refreshNotificationPermissionStatus()
    }

    static func isCompleted() -> Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    var navigationSteps: [Step] {
        Step.allCases
    }

    func isStepReachableInNavigation(_ target: Step) -> Bool {
        target.rawValue <= highestReachedStepRaw
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
        step = .cluster
        formError = nil
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
        case .cluster:
            step = .welcome
        case .sshKey:
            step = .cluster
        case .networkPermission:
            step = .sshKey
        case .testing:
            cancelTesting()
            step = .sshKey
        case .notifications:
            step = .testing
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

    func refreshNotificationPermissionStatus() {
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
        "\(resolvedUsername) @ \(hostname.trimmingCharacters(in: .whitespacesAndNewlines))"
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
            setStep(.ssh, .running)
            try await connection.establishMaster()
            setStep(.ssh, .done, label: "SSH connection established")

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
            setStep(activeStep, .fail)
            canContinueAfterTest = false
            testErrorMessage = Self.userFacingError(error)
        }

        await connection.teardown()
        isTestingConnection = false
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
        Self.markCompleted()
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

    private static func userFacingError(_ error: Error) -> String {
        if let orbitError = error as? OrbitServiceError {
            return orbitError.localizedDescription
        }

        var message = error.localizedDescription
        if let firstLine = message.split(separator: "\n").first {
            message = String(firstLine)
        }

        if message.count > 180 {
            message = String(message.prefix(180)) + "…"
        }

        return message
    }
}
