import AppKit
import Combine
import Foundation
import Sparkle

public struct OrbitUpdaterConfiguration: Equatable, Sendable {
    public let isApplicationBundle: Bool
    public let feedURL: URL?
    public let publicEDKey: String?

    public init(isApplicationBundle: Bool, feedURL: URL?, publicEDKey: String?) {
        self.isApplicationBundle = isApplicationBundle
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let feedValue = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyValue = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.init(
            isApplicationBundle: bundle.bundleURL.pathExtension.lowercased() == "app",
            feedURL: feedValue.flatMap(URL.init(string:)),
            publicEDKey: keyValue
        )
    }

    public var validationError: String? {
        guard isApplicationBundle else {
            return "Updates are available in the packaged Orbit.app build."
        }
        guard let feedURL else {
            return "Orbit's update feed is not configured."
        }
        guard feedURL.scheme?.lowercased() == "https" || feedURL.isLoopbackHTTP else {
            return "Orbit's update feed must use HTTPS."
        }
        guard let publicEDKey, !publicEDKey.isEmpty else {
            return "Orbit's update verification key is not configured."
        }
        return nil
    }

    public var isValid: Bool {
        validationError == nil
    }
}

private extension URL {
    var isLoopbackHTTP: Bool {
        guard scheme?.lowercased() == "http" else { return false }
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public enum OrbitUpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case available
    case downloading
    case extracting
    case readyToInstall
    case installing
    case upToDate
    case failed
}

@MainActor
private final class OrbitUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let installsImmediatelyForIntegrationTesting: Bool

    init(installsImmediatelyForIntegrationTesting: Bool) {
        self.installsImmediatelyForIntegrationTesting = installsImmediatelyForIntegrationTesting
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        guard installsImmediatelyForIntegrationTesting else { return false }
        Task { @MainActor in
            immediateInstallHandler()
        }
        return true
    }
}

@MainActor
private final class OrbitUpdateUserDriver: NSObject, SPUUserDriver {
    weak var owner: OrbitUpdaterController?

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: false,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.didStartUserInitiatedCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        owner?.didFindUpdate(item: appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        owner?.didReceiveReleaseNotes(downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        owner?.didFailToLoadReleaseNotes(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.didNotFindUpdate(error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.didFail(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.didStartDownload(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.didReceiveExpectedDownloadLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.didReceiveDownloadData(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.didStartExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        owner?.didReceiveExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.didBecomeReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        owner?.didStartInstalling(
            applicationTerminated: applicationTerminated,
            retry: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        owner?.didFinishInstallation(relaunched: relaunched)
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        owner?.didDismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        owner?.requestPresentation(expanded: true)
    }
}

@MainActor
public final class OrbitUpdaterController: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecksForUpdates = false

    @Published public private(set) var phase: OrbitUpdatePhase = .idle
    @Published public private(set) var availableVersion: String?
    @Published public private(set) var updateTitle: String?
    @Published public private(set) var releaseNotes: String?
    @Published public private(set) var releaseNotesError: String?
    @Published public private(set) var isInformationOnlyUpdate = false
    @Published public private(set) var releasePageURL: URL?
    @Published public private(set) var progress: Double?
    @Published public private(set) var statusDetail: String?
    @Published public private(set) var isExpanded = false

    public let unavailableReason: String?
    public var onRequestPresentation: (() -> Void)?

    private var updater: SPUUpdater?
    private var updaterDelegate: OrbitUpdaterDelegate?
    private var userDriver: OrbitUpdateUserDriver?
    private var observations: Set<AnyCancellable> = []
    private let installsAutomaticallyForIntegrationTesting: Bool

    private var updateChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyToInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var expectedDownloadLength: UInt64 = 0
    private var receivedDownloadLength: UInt64 = 0

    public convenience init(bundle: Bundle = .main) {
        self.init(configuration: OrbitUpdaterConfiguration(bundle: bundle), bundle: bundle)
    }

    init(configuration: OrbitUpdaterConfiguration, bundle: Bundle = .main) {
        let installsAutomaticallyForIntegrationTesting =
            ProcessInfo.processInfo.environment["ORBIT_TEST_AUTO_INSTALL_UPDATE"] == "1"
        self.installsAutomaticallyForIntegrationTesting = installsAutomaticallyForIntegrationTesting
        unavailableReason = configuration.validationError
        guard configuration.isValid else { return }

        let driver = OrbitUpdateUserDriver()
        let delegate = OrbitUpdaterDelegate(
            installsImmediatelyForIntegrationTesting: installsAutomaticallyForIntegrationTesting
        )
        userDriver = driver
        updaterDelegate = delegate
        driver.owner = self

        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: driver,
            delegate: delegate
        )
        self.updater = updater

        // Orbit may check automatically, but the update archive is only
        // downloaded after the user explicitly approves the release.
        updater.automaticallyDownloadsUpdates = false

        do {
            try updater.start()
            updater.automaticallyDownloadsUpdates = false
        } catch {
            phase = .failed
            statusDetail = error.localizedDescription
            return
        }

        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &observations)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.automaticallyChecksForUpdates = value }
            .store(in: &observations)
    }

    public var isAvailable: Bool { updater != nil }

    public var shouldShowStatus: Bool {
        phase != .idle
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .extracting, .installing:
            return true
        default:
            return false
        }
    }

    public func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        isExpanded = true
        requestPresentation(expanded: true)
        updater.checkForUpdates()
    }

    public func checkForUpdatesForIntegrationTesting() {
        updater?.checkForUpdates()
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    public func toggleExpanded() {
        isExpanded.toggle()
    }

    public func showDetails() {
        isExpanded = true
        requestPresentation(expanded: true)
    }

    public func openReleasePage() {
        guard let releasePageURL else { return }
        NSWorkspace.shared.open(releasePageURL)
    }

    public func openInformationOnlyUpdate() {
        guard releasePageURL != nil else { return }
        openReleasePage()
        remindLater()
    }

    public func downloadAndInstallUpdate() {
        guard let reply = takeUpdateChoiceReply() else { return }
        phase = .downloading
        progress = nil
        statusDetail = "Preparing secure download…"
        reply(.install)
    }

    public func remindLater() {
        if let reply = takeUpdateChoiceReply() {
            reply(.dismiss)
        } else if let reply = takeReadyToInstallReply() {
            reply(.dismiss)
        }
        clearPresentation()
    }

    public func skipThisVersion() {
        guard let reply = takeUpdateChoiceReply() else {
            clearPresentation()
            return
        }
        reply(.skip)
        clearPresentation()
    }

    public func installAndRelaunch() {
        // A resumed installation arrives through showUpdateFound(stage: .installing)
        // and therefore still owns the original update-choice reply.
        guard let reply = takeReadyToInstallReply() ?? takeUpdateChoiceReply() else { return }
        phase = .installing
        progress = nil
        statusDetail = "Orbit will reopen automatically."
        reply(.install)
    }

    public func cancelCurrentOperation() {
        if phase == .checking {
            checkCancellation?()
        } else if phase == .downloading {
            downloadCancellation?()
        }
        clearPresentation()
    }

    public func retryTerminatingApplication() {
        retryTermination?()
    }

    public func dismissStatus() {
        guard !isBusy else { return }
        clearPresentation()
    }

    fileprivate func didStartUserInitiatedCheck(cancellation: @escaping () -> Void) {
        resetUpdateDetails()
        phase = .checking
        statusDetail = "Looking for a newer Orbit release…"
        checkCancellation = cancellation
        requestPresentation(expanded: true)
    }

    fileprivate func didFindUpdate(
        item: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        resetUpdateDetails(keepingExpansion: true)
        availableVersion = item.displayVersionString
        updateTitle = item.title
        releaseNotes = decodedEmbeddedReleaseNotes(from: item)
        isInformationOnlyUpdate = item.isInformationOnlyUpdate
        releasePageURL = item.infoURL
        updateChoiceReply = reply
        checkCancellation = nil

        if installsAutomaticallyForIntegrationTesting, !item.isInformationOnlyUpdate {
            updateChoiceReply = nil
            phase = .downloading
            statusDetail = "Preparing integration-test download…"
            reply(.install)
            return
        }

        if item.isInformationOnlyUpdate {
            phase = .available
            statusDetail = "This release must be opened on the Orbit website."
        } else {
            switch state.stage {
            case .notDownloaded:
                phase = .available
                statusDetail = "Review this signed release before downloading."
            case .downloaded:
                phase = .available
                statusDetail = "This update is downloaded and ready to prepare."
            case .installing:
                phase = .readyToInstall
                statusDetail = "This update is ready to install."
            @unknown default:
                phase = .available
                statusDetail = "Review this signed release before downloading."
            }
        }

        requestPresentation(expanded: true)
    }

    fileprivate func didReceiveReleaseNotes(_ downloadData: SPUDownloadData) {
        releaseNotes = decodeReleaseNotes(downloadData)
        releaseNotesError = nil
    }

    fileprivate func didFailToLoadReleaseNotes(_ error: Error) {
        releaseNotesError = "Release notes could not be loaded."
    }

    fileprivate func didNotFindUpdate(_ error: Error) {
        resetUpdateDetails(keepingExpansion: true)
        phase = .upToDate
        statusDetail = "No newer compatible Orbit update is available."
        requestPresentation(expanded: true)
    }

    fileprivate func didFail(_ error: Error) {
        phase = .failed
        progress = nil
        statusDetail = error.localizedDescription
        requestPresentation(expanded: true)
    }

    fileprivate func didStartDownload(cancellation: @escaping () -> Void) {
        phase = .downloading
        statusDetail = "Downloading signed update…"
        progress = nil
        downloadCancellation = cancellation
        receivedDownloadLength = 0
    }

    fileprivate func didReceiveExpectedDownloadLength(_ length: UInt64) {
        expectedDownloadLength = length
        receivedDownloadLength = 0
        progress = length > 0 ? 0 : nil
    }

    fileprivate func didReceiveDownloadData(_ length: UInt64) {
        receivedDownloadLength += length
        if receivedDownloadLength > expectedDownloadLength {
            expectedDownloadLength = receivedDownloadLength
        }
        if expectedDownloadLength > 0 {
            progress = min(1, Double(receivedDownloadLength) / Double(expectedDownloadLength))
        }
    }

    fileprivate func didStartExtracting() {
        phase = .extracting
        progress = nil
        statusDetail = "Verifying and preparing update…"
        downloadCancellation = nil
    }

    fileprivate func didReceiveExtractionProgress(_ value: Double) {
        phase = .extracting
        progress = min(1, max(0, value))
    }

    fileprivate func didBecomeReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installsAutomaticallyForIntegrationTesting {
            phase = .installing
            progress = nil
            statusDetail = "Installing integration-test update…"
            reply(.install)
            return
        }

        readyToInstallReply = reply
        phase = .readyToInstall
        progress = nil
        statusDetail = "Verified and ready to relaunch."
        requestPresentation(expanded: true)
    }

    fileprivate func didStartInstalling(
        applicationTerminated: Bool,
        retry: @escaping () -> Void
    ) {
        phase = .installing
        statusDetail = applicationTerminated
            ? "Installing Orbit…"
            : "Waiting for Orbit to quit…"
        retryTermination = retry
    }

    fileprivate func didFinishInstallation(relaunched: Bool) {
        phase = .idle
        clearPresentation()
    }

    fileprivate func didDismissUpdateInstallation() {
        checkCancellation = nil
        downloadCancellation = nil
        retryTermination = nil
    }

    fileprivate func requestPresentation(expanded: Bool) {
        if expanded { isExpanded = true }
        onRequestPresentation?()
    }

    private func takeUpdateChoiceReply() -> ((SPUUserUpdateChoice) -> Void)? {
        defer { updateChoiceReply = nil }
        return updateChoiceReply
    }

    private func takeReadyToInstallReply() -> ((SPUUserUpdateChoice) -> Void)? {
        defer { readyToInstallReply = nil }
        return readyToInstallReply
    }

    private func clearPresentation() {
        phase = .idle
        isExpanded = false
        resetUpdateDetails()
    }

    private func resetUpdateDetails(keepingExpansion: Bool = false) {
        availableVersion = nil
        updateTitle = nil
        releaseNotes = nil
        releaseNotesError = nil
        isInformationOnlyUpdate = false
        releasePageURL = nil
        progress = nil
        statusDetail = nil
        checkCancellation = nil
        downloadCancellation = nil
        retryTermination = nil
        updateChoiceReply = nil
        readyToInstallReply = nil
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        if !keepingExpansion { isExpanded = false }
    }

    private func decodedEmbeddedReleaseNotes(from item: SUAppcastItem) -> String? {
        guard let description = item.itemDescription, !description.isEmpty else { return nil }
        if item.itemDescriptionFormat == "html" {
            return plainTextFromHTML(Data(description.utf8))
        }
        return description
    }

    private func decodeReleaseNotes(_ downloadData: SPUDownloadData) -> String? {
        let extensionName = downloadData.url.pathExtension.lowercased()
        let mime = downloadData.mimeType?.lowercased() ?? ""
        if extensionName == "html" || extensionName == "htm" || mime.contains("html") {
            return plainTextFromHTML(downloadData.data)
        }

        if let encodingName = downloadData.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let text = String(data: downloadData.data, encoding: String.Encoding(rawValue: encoding)) {
                    return text
                }
            }
        }
        return String(data: downloadData.data, encoding: .utf8)
    }

    private func plainTextFromHTML(_ data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) else { return String(data: data, encoding: .utf8) }
        return attributed.string
    }
}
