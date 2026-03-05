import Foundation
import AppKit
import OrbitCore

@MainActor
final class OrbitMenuBarViewModel: ObservableObject {
    enum Indicator: String {
        case healthy = "●"
        case pending = "◐"
        case warning = "⚠"
        case failure = "✕"
        case disconnected = "○"
    }

    struct ArrayRunningGroup: Identifiable, Equatable {
        let parentJobID: String
        let name: String
        let done: Int
        let total: Int
        let running: Int
        let pending: Int
        let runningChildren: [JobSnapshot]
        let representativeJob: JobSnapshot?

        var id: String { parentJobID }

        var completion: Double {
            guard total > 0 else { return 0 }
            return min(1.0, max(0.0, Double(done) / Double(total)))
        }

        var completionPercent: Int {
            Int((completion * 100).rounded())
        }
    }

    struct NodeLoadRow: Identifiable, Equatable {
        enum Severity: Int {
            case critical = 0
            case warning = 1
            case healthy = 2
            case unknown = 3
        }

        let id: String
        let name: String
        let state: String
        let cpuText: String
        let gpuText: String?
        let gpuUsedCount: Int?
        let gpuTotalCount: Int?
        let cpuLoadPercent: Double
        let severity: Severity
        let sortKey: Int
        let node: NodeInventoryEntry
    }

    struct UpdateNotice: Equatable {
        let versionTag: String
        let releaseURL: URL
    }

    @Published private(set) var statuses: [ProfileStatus] = []
    @Published var selectedProfileID: UUID? {
        didSet {
            loadCPUHistory()
            refreshSelectedWeeklyUsage()
            clearSelectedJob()
            expandedArrayParentID = nil
            expandedRunningJobID = nil
            applyCachedNodeInventoryForSelectedProfile()

            if isClusterLoadExpanded {
                loadNodeInventory(force: false)
            }
        }
    }
    @Published private(set) var cpuHistory: [CPUCoreDataPoint] = []
    @Published private(set) var indicator: Indicator = .disconnected
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastError: String?
    @Published var selectedJob: JobSnapshot?
    @Published private(set) var selectedJobHistory: JobHistorySnapshot?
    @Published var expandedArrayParentID: String?
    @Published var expandedRunningJobID: String?
    @Published private(set) var isClusterLoadExpanded: Bool = false
    @Published private(set) var selectedNodeInventory: NodeInventoryResult?
    @Published private(set) var isLoadingNodeInventory: Bool = false
    @Published private(set) var selectedWeeklyUsage: WeeklyUsageSummary?
    @Published private(set) var cpuHourRatePerHour: Double = OrbitAppSettings.cpuHourRate()
    @Published private(set) var availableUpdateNotice: UpdateNotice?

    private let service: OrbitService
    private let updateChecker: OrbitUpdateChecker
    private var watchTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var watchedProfileIDs: Set<UUID> = []
    private var isReloading = false
    private var started = false
    private var isCheckingForUpdates = false
    private var defaultsObserver: NSObjectProtocol?
    private var idleSinceByProfile: [UUID: Date] = [:]

    private var nodeInventoryCache: [UUID: NodeInventoryResult] = [:]
    private var nodeInventoryLastFetchAt: [UUID: Date] = [:]
    private let nodeInventoryRefreshInterval: TimeInterval = 45

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(service: OrbitService, updateChecker: OrbitUpdateChecker = OrbitUpdateChecker()) {
        self.service = service
        self.updateChecker = updateChecker
        self.cpuHourRatePerHour = OrbitAppSettings.cpuHourRate()

        if let currentVersion = updateChecker.currentAppVersion() {
            availableUpdateNotice = updateChecker.cachedAvailableUpdate(forCurrentVersion: currentVersion).map {
                UpdateNotice(versionTag: $0.versionTag, releaseURL: $0.releaseURL)
            }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cpuHourRatePerHour = OrbitAppSettings.cpuHourRate()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func start() {
        guard !started else { return }
        started = true

        service.startLifecycleMonitoring()
        scheduleReload(refresh: false)
        startHeartbeatLoop()
        checkForUpdates(force: false)
    }

    func stop() {
        started = false
        watchTask?.cancel()
        watchTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        service.stopLifecycleMonitoring()
        Task {
            await service.shutdown()
        }
    }

    func refreshNow() {
        scheduleReload(refresh: true)
    }

    var selectedStatus: ProfileStatus? {
        guard let selectedProfileID else { return statuses.first }
        return statuses.first(where: { $0.profile.id == selectedProfileID }) ?? statuses.first
    }

    var selectedHasActiveJobs: Bool {
        guard let status = selectedStatus else { return false }
        return status.liveJobs.contains { OrbitMenuBarJobGrouping.isActiveState($0.state) }
    }

    var selectedIdleSince: Date? {
        guard let profileID = selectedStatus?.profile.id else { return nil }
        return idleSinceByProfile[profileID]
    }

    var selectedEstimatedCostThisWeek: Double? {
        guard let weekly = selectedWeeklyUsage else { return nil }
        return weekly.totalCPUHours * cpuHourRatePerHour
    }

    var selectedArrayGroups: [ArrayRunningGroup] {
        guard let status = selectedStatus else { return [] }
        return OrbitMenuBarJobGrouping.arrayGroups(from: status)
    }

    var selectedSingleRunningJobs: [JobSnapshot] {
        guard let status = selectedStatus else { return [] }
        let groupedArrayParentIDs = Set(selectedArrayGroups.map(\.parentJobID))
        return OrbitMenuBarJobGrouping.singleRunningJobs(from: status, groupedArrayParentIDs: groupedArrayParentIDs)
    }

    var selectedPendingJobs: [JobSnapshot] {
        guard let status = selectedStatus else { return [] }
        let groupedArrayParentIDs = Set(selectedArrayGroups.map(\.parentJobID))
        return OrbitMenuBarJobGrouping.pendingJobs(from: status, groupedArrayParentIDs: groupedArrayParentIDs)
    }

    var allLoads: [(name: String, load: ClusterLoad?)] {
        statuses
            .sorted { $0.profile.displayName.localizedCaseInsensitiveCompare($1.profile.displayName) == .orderedAscending }
            .map { ($0.profile.displayName, $0.clusterLoad) }
    }

    var selectedNodeRows: [NodeLoadRow] {
        guard let inventory = selectedNodeInventory else { return [] }

        return inventory.nodes
            .map { node in
                let totalCPU = max(0, node.totalCPUs)
                let allocatedCPU = max(0, min(node.allocatedCPUs, totalCPU))
                let cpuPercent = totalCPU > 0 ? (Double(allocatedCPU) / Double(totalCPU) * 100.0) : 0

                let cpuText: String
                if totalCPU > 0 {
                    cpuText = "\(allocatedCPU)/\(totalCPU)"
                } else {
                    cpuText = "—"
                }

                let state = normalizedState(node.state)
                let severity = severityForNodeState(state)

                let gpuTotal = parseGPUCount(node.gres)
                let gpuUsed = parseGPUCount(node.gresUsed)
                let gpuText: String?
                if let gpuTotal {
                    if let gpuUsed {
                        gpuText = "\(max(0, min(gpuUsed, gpuTotal)))/\(gpuTotal)"
                    } else {
                        gpuText = "\(gpuTotal)"
                    }
                } else {
                    gpuText = nil
                }

                return NodeLoadRow(
                    id: node.name,
                    name: node.name,
                    state: state,
                    cpuText: cpuText,
                    gpuText: gpuText,
                    gpuUsedCount: gpuUsed,
                    gpuTotalCount: gpuTotal,
                    cpuLoadPercent: cpuPercent,
                    severity: severity,
                    sortKey: severity.rawValue,
                    node: node
                )
            }
            .sorted { lhs, rhs in
                if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                if abs(lhs.cpuLoadPercent - rhs.cpuLoadPercent) > 0.001 {
                    return lhs.cpuLoadPercent > rhs.cpuLoadPercent
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var selectedTotalGPUs: Int {
        selectedNodeRows.reduce(0) { partial, row in
            partial + max(0, row.gpuTotalCount ?? 0)
        }
    }

    var selectedAllocatedGPUs: Int? {
        let gpuRows = selectedNodeRows.filter { ($0.gpuTotalCount ?? 0) > 0 }
        guard !gpuRows.isEmpty else { return nil }
        guard gpuRows.allSatisfy({ $0.gpuUsedCount != nil }) else { return nil }

        return gpuRows.reduce(0) { partial, row in
            let total = max(0, row.gpuTotalCount ?? 0)
            let used = max(0, min(row.gpuUsedCount ?? 0, total))
            return partial + used
        }
    }

    var selectedPartitions: [String] {
        if let overviewPartitions = selectedStatus?.clusterOverview?.partitions,
           !overviewPartitions.isEmpty {
            return overviewPartitions
        }

        guard let inventory = selectedNodeInventory else { return [] }

        return Array(Set(inventory.nodes.flatMap(\.partitions)))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    var selectedCurrentCores: Int {
        if let latest = cpuHistory.last?.totalCoresInUse {
            return latest
        }

        return selectedStatus?.liveJobs
            .filter { $0.state == .running || $0.state == .completing }
            .reduce(0) { $0 + max(0, $1.cpus) } ?? 0
    }

    var chartCPUHistory: [CPUCoreDataPoint] {
        paddedCPUHistory(lastHours: 6)
    }

    var selectedLastUpdatedText: String {
        guard let date = selectedStatus?.lastSuccessfulPollAt else {
            return "never"
        }

        return Self.clockFormatter.string(from: date)
    }

    var selectedIsStale: Bool {
        guard let status = selectedStatus,
              let last = status.lastSuccessfulPollAt else { return true }
        let staleAfter = max(status.profile.pollIntervalSeconds * 2, 120)
        return Date().timeIntervalSince(last) > TimeInterval(staleAfter)
    }

    var selectedStaleAgeText: String? {
        guard selectedIsStale,
              let status = selectedStatus,
              let last = status.lastSuccessfulPollAt else {
            return nil
        }

        return formatAge(Int(Date().timeIntervalSince(last)))
    }

    var selectedUpdatedFooterText: String {
        if let stale = selectedStaleAgeText {
            return "updated \(selectedLastUpdatedText) (stale \(stale))"
        }
        return "updated \(selectedLastUpdatedText)"
    }

    var selectedGrafanaURL: URL? {
        guard let raw = selectedStatus?.profile.grafanaURL else { return nil }
        return URL(string: raw)
    }

    func openGrafana() {
        guard let url = selectedGrafanaURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openAvailableUpdateReleasePage() {
        guard let notice = availableUpdateNotice else { return }
        NSWorkspace.shared.open(notice.releaseURL)
    }

    func dismissAvailableUpdateNotice() {
        guard let notice = availableUpdateNotice else { return }
        updateChecker.dismiss(versionTag: notice.versionTag)
        availableUpdateNotice = nil
    }

    func selectJob(_ job: JobSnapshot) {
        selectedJob = job
        loadSelectedJobHistory(job)
    }

    func clearSelectedJob() {
        selectedJob = nil
        selectedJobHistory = nil
    }

    func toggleArrayExpansion(parentJobID: String) {
        if expandedArrayParentID == parentJobID {
            expandedArrayParentID = nil
        } else {
            expandedArrayParentID = parentJobID
            expandedRunningJobID = nil
            isClusterLoadExpanded = false
        }
    }

    func toggleRunningJobExpansion(jobID: String) {
        if expandedRunningJobID == jobID {
            expandedRunningJobID = nil
        } else {
            expandedRunningJobID = jobID
            expandedArrayParentID = nil
            isClusterLoadExpanded = false
        }
    }

    func toggleClusterLoadExpansion() {
        isClusterLoadExpanded.toggle()
        if isClusterLoadExpanded {
            expandedArrayParentID = nil
            expandedRunningJobID = nil
            loadNodeInventory(force: false)
        }
    }

    func refreshNodeInventory() {
        loadNodeInventory(force: true)
    }

    private func checkForUpdates(force: Bool) {
        guard !isCheckingForUpdates else { return }
        guard let currentVersion = updateChecker.currentAppVersion() else { return }

        isCheckingForUpdates = true

        Task { [weak self] in
            guard let self else { return }

            let update = await self.updateChecker.checkForUpdate(currentVersion: currentVersion, force: force)

            await MainActor.run {
                self.availableUpdateNotice = update.map {
                    UpdateNotice(versionTag: $0.versionTag, releaseURL: $0.releaseURL)
                }
                self.isCheckingForUpdates = false
            }
        }
    }

    private func startWatchLoop() {
        watchTask?.cancel()

        watchTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await service.watchAll(iterations: nil) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.scheduleReload(refresh: false)
                    }
                }
            } catch let error as OrbitServiceError {
                await MainActor.run {
                    switch error {
                    case .noActiveProfiles:
                        self.lastError = nil
                    case .invalidProfile(let message):
                        self.lastError = message
                    case .legacySlurmUnsupported:
                        self.lastError = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()

        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                } catch {
                    break
                }

                if Task.isCancelled { break }
                await MainActor.run {
                    self.scheduleReload(refresh: false)
                    self.checkForUpdates(force: false)
                }
            }
        }
    }

    private func scheduleReload(refresh: Bool) {
        guard !isReloading else { return }

        Task {
            await reloadStatuses(refresh: refresh)
        }
    }

    private func reloadStatuses(refresh: Bool) async {
        guard !isReloading else { return }
        isReloading = true
        if refresh { isRefreshing = true }

        defer {
            isReloading = false
            isRefreshing = false
        }

        do {
            let loaded = try await service.statusAll(refresh: refresh, activeOnly: false)
            statuses = loaded

            if let selectedProfileID, loaded.contains(where: { $0.profile.id == selectedProfileID }) {
                // keep selection
            } else {
                selectedProfileID = loaded.first?.profile.id
            }

            let activeIDs = Set(loaded.filter { $0.profile.isActive }.map { $0.profile.id })
            if activeIDs != watchedProfileIDs {
                watchedProfileIDs = activeIDs
                if activeIDs.isEmpty {
                    watchTask?.cancel()
                    watchTask = nil
                } else {
                    startWatchLoop()
                }
            }

            indicator = computeIndicator(from: loaded)
            lastError = nil
            updateIdleSince(statuses: loaded)
            loadCPUHistory()
            refreshSelectedWeeklyUsage()
            syncSelectedJobWithLatestData()
            applyCachedNodeInventoryForSelectedProfile()

            if let expanded = expandedArrayParentID,
               !selectedArrayGroups.contains(where: { $0.parentJobID == expanded }) {
                expandedArrayParentID = nil
            }

            if let expanded = expandedRunningJobID,
               !selectedSingleRunningJobs.contains(where: { $0.id == expanded }) {
                expandedRunningJobID = nil
            }

            if isClusterLoadExpanded {
                loadNodeInventory(force: false)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadCPUHistory() {
        guard let profileID = selectedStatus?.profile.id else {
            cpuHistory = []
            return
        }

        do {
            cpuHistory = try service.cpuCoreHistory(profileId: profileID, lastHours: 6)
        } catch {
            cpuHistory = []
            lastError = error.localizedDescription
        }
    }

    private func refreshSelectedWeeklyUsage() {
        guard let status = selectedStatus else {
            selectedWeeklyUsage = nil
            return
        }

        do {
            selectedWeeklyUsage = try service.weeklyUsage(profileId: status.profile.id)
        } catch {
            selectedWeeklyUsage = nil
        }
    }

    private func updateIdleSince(statuses: [ProfileStatus]) {
        var next = idleSinceByProfile

        for status in statuses {
            let profileID = status.profile.id
            let hasActive = status.liveJobs.contains { OrbitMenuBarJobGrouping.isActiveState($0.state) }

            if hasActive {
                next[profileID] = nil
                continue
            }

            if next[profileID] == nil {
                next[profileID] = status.lastSuccessfulPollAt ?? Date()
            }
        }

        let validIDs = Set(statuses.map { $0.profile.id })
        for key in next.keys where !validIDs.contains(key) {
            next[key] = nil
        }

        idleSinceByProfile = next
    }

    private func syncSelectedJobWithLatestData() {
        guard let selected = selectedJob else { return }

        if let updated = selectedStatus?.liveJobs.first(where: { $0.id == selected.id }) {
            selectedJob = updated
            loadSelectedJobHistory(updated)
        }
    }

    private func loadSelectedJobHistory(_ job: JobSnapshot) {
        do {
            selectedJobHistory = try service.historyEntry(profileId: job.profileId, jobId: job.id)
        } catch {
            selectedJobHistory = nil
            lastError = error.localizedDescription
        }
    }

    private func applyCachedNodeInventoryForSelectedProfile() {
        guard let profileID = selectedStatus?.profile.id else {
            selectedNodeInventory = nil
            return
        }
        selectedNodeInventory = nodeInventoryCache[profileID]
    }

    private func loadNodeInventory(force: Bool) {
        guard let profileID = selectedStatus?.profile.id else {
            selectedNodeInventory = nil
            return
        }

        if !force,
           let last = nodeInventoryLastFetchAt[profileID],
           Date().timeIntervalSince(last) < nodeInventoryRefreshInterval {
            selectedNodeInventory = nodeInventoryCache[profileID]
            return
        }

        guard !isLoadingNodeInventory else { return }
        isLoadingNodeInventory = true

        Task {
            defer {
                Task { @MainActor in
                    self.isLoadingNodeInventory = false
                }
            }

            do {
                let inventory = try await service.nodeInventory(identifier: profileID.uuidString)
                await MainActor.run {
                    self.nodeInventoryCache[profileID] = inventory
                    self.nodeInventoryLastFetchAt[profileID] = Date()
                    if self.selectedStatus?.profile.id == profileID {
                        self.selectedNodeInventory = inventory
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    if self.selectedStatus?.profile.id == profileID {
                        self.selectedNodeInventory = self.nodeInventoryCache[profileID]
                    }
                }
            }
        }
    }

}
