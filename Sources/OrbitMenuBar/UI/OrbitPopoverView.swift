import SwiftUI
#if canImport(Charts)
import Charts
#endif
import OrbitCore
import OrbitMacAppSupport

struct OrbitPopoverView: View {
    @ObservedObject var viewModel: OrbitMenuBarViewModel
    @ObservedObject var presentation: OrbitMenuBarPresentationModel
    let onOpenSettings: () -> Void

    private var updater: OrbitUpdaterController {
        presentation.updaterController
    }

    @State private var forceShowStats: Bool = false
    @State private var isRunningExpanded: Bool = false
    @State private var isPendingExpanded: Bool = false
    @State private var selectedNodePartition: String?

    private let maxRunningRows = 3
    private let maxPendingRows = 3

    enum Layout {
        static let width: CGFloat = 380
        static let maxHeight: CGFloat = 800
        static let detailInset: CGFloat = 8
    }

    enum Formatters {
        static let idleSince: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter
        }()

        static let weekdayShort: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE"
            return formatter
        }()

        static let monthDay: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d"
            return formatter
        }()

        static let dayOnly: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "d"
            return formatter
        }()

        static let hourMinute: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter
        }()
    }

    enum RunningEntry: Identifiable {
        case array(OrbitMenuBarViewModel.ArrayRunningGroup)
        case single(JobSnapshot)

        var id: String {
            switch self {
            case .array(let group):
                return "array-\(group.parentJobID)"
            case .single(let job):
                return "job-\(job.id)"
            }
        }

        var isArray: Bool {
            if case .array = self { return true }
            return false
        }
    }

    var body: some View {
        Group {
            if let onboardingViewModel = presentation.onboardingViewModel {
                OrbitOnboardingView(viewModel: onboardingViewModel)
                    .padding(8)
                    .frame(width: Layout.width)
                    .preferredColorScheme(.dark)
            } else {
                dashboardBody
                    .sheet(item: $viewModel.selectedJob) { job in
                        OrbitJobDetailView(
                            clusterName: viewModel.selectedStatus?.profile.displayName ?? "Cluster",
                            job: job,
                            history: viewModel.selectedJobHistory,
                            sacctAvailable: viewModel.selectedStatus?.sacctAvailable ?? false,
                            onClose: { viewModel.clearSelectedJob() }
                        )
                    }
            }
        }
    }

    private var dashboardBody: some View {
        ZStack(alignment: .top) {
            OrbitTheme.background.opacity(0.95)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                headerSection
                divider
                trackingSection
                divider

                if shouldShowStatsScreen {
                    idleSection
                    divider
                    clusterLoadSection
                    divider
                    footerSection
                } else {
                    cpuSection
                    divider
                    jobsSection
                    divider
                    clusterLoadSection
                    divider
                    footerSection
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(width: Layout.width - 16, alignment: .leading)
            .clipped()
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OrbitTheme.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)
            }
        }
        .padding(8)
        .frame(width: Layout.width)
        .frame(maxHeight: Layout.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .transaction { t in t.animation = nil }
        .onChange(of: viewModel.selectedHasActiveJobs) { hasActive in
            if !hasActive {
                forceShowStats = false
                isRunningExpanded = false
                isPendingExpanded = false
            }
        }
        .onChange(of: viewModel.selectedProfileID) { _ in
            forceShowStats = false
            isRunningExpanded = false
            isPendingExpanded = false
            selectedNodePartition = nil
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 10) {
            Text("ORBIT")
                .font(OrbitTheme.mono(12, weight: .semibold))
                .foregroundStyle(OrbitTheme.textLabel)
                .tracking(1.2)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if canToggleStatsScreen {
                    Button(forceShowStats ? "OVERVIEW" : "STATS") {
                        forceShowStats.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(OrbitTheme.mono(10, weight: .semibold))
                    .foregroundStyle(forceShowStats ? OrbitTheme.accent : OrbitTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(forceShowStats ? OrbitTheme.accent.opacity(0.14) : OrbitTheme.mutedFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(forceShowStats ? OrbitTheme.accent.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                if viewModel.statuses.count > 1 {
                    ForEach(viewModel.statuses, id: \.profile.id) { status in
                        let isSelected = status.profile.id == viewModel.selectedStatus?.profile.id
                        Button(status.profile.displayName) {
                            viewModel.selectedProfileID = status.profile.id
                        }
                        .buttonStyle(.plain)
                        .font(OrbitTheme.mono(10, weight: .semibold))
                        .foregroundStyle(isSelected ? OrbitTheme.accent : OrbitTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isSelected ? OrbitTheme.accent.opacity(0.16) : OrbitTheme.mutedFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isSelected ? OrbitTheme.accent.opacity(0.35) : Color.white.opacity(0.07), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                } else if let selected = viewModel.selectedStatus {
                    Text(selected.profile.displayName)
                        .font(OrbitTheme.mono(10, weight: .semibold))
                        .foregroundStyle(OrbitTheme.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(selected.profile.displayName)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(OrbitTheme.accent.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(OrbitTheme.accent.opacity(0.35), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var trackingSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.selectedIsStale ? OrbitTheme.warning : OrbitTheme.success)
                .frame(width: 6, height: 6)

            if let selected = viewModel.selectedStatus {
                Text("tracking \(selected.profile.username)")
                    .font(OrbitTheme.mono(12))
                    .foregroundStyle(OrbitTheme.textSecondary)

                Text("@ \(selected.profile.displayName)")
                    .font(OrbitTheme.mono(11, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(selected.profile.displayName)

                if let stale = viewModel.selectedStaleAgeText {
                    Text("(stale \(stale))")
                        .font(OrbitTheme.mono(11))
                        .foregroundStyle(OrbitTheme.warning)
                }
            } else {
                Text("tracking —")
                    .font(OrbitTheme.mono(12))
                    .foregroundStyle(OrbitTheme.textLabel)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var idleSection: some View {
        OrbitIdleStateView(data: idleViewData)
    }

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MY CPU CORES")
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textLabel)
                    .tracking(1.1)

                Spacer()

                Text("\(viewModel.selectedCurrentCores)")
                    .font(OrbitTheme.mono(28, weight: .semibold))
                    .foregroundStyle(OrbitTheme.accent)
                Text("cores")
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textSecondary)
            }

            chartView

            HStack {
                Text("-6h")
                Spacer()
                Text("-4h")
                Spacer()
                Text("-2h")
                Spacer()
                Text("now")
            }
            .font(OrbitTheme.mono(11))
            .foregroundStyle(OrbitTheme.textTimestamp)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var chartView: some View {
        #if canImport(Charts)
        if viewModel.chartCPUHistory.count >= 2 {
            let lastTimestamp = viewModel.chartCPUHistory.last?.timestamp
            Chart(viewModel.chartCPUHistory, id: \.timestamp) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Cores", point.totalCoresInUse)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [OrbitTheme.accent.opacity(0.35), OrbitTheme.accent.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Cores", point.totalCoresInUse)
                )
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .foregroundStyle(OrbitTheme.accent)

                if point.timestamp == lastTimestamp {
                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Cores", point.totalCoresInUse)
                    )
                    .symbolSize(52)
                    .foregroundStyle(OrbitTheme.accent)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 84)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OrbitTheme.mutedFill)
                .frame(height: 84)
                .overlay(alignment: .leading) {
                    Text(viewModel.statuses.isEmpty ? "No profile data" : "Collecting data…")
                        .font(OrbitTheme.mono(11))
                        .foregroundStyle(OrbitTheme.textTimestamp)
                        .padding(.horizontal, 10)
                }
        }
        #else
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(OrbitTheme.mutedFill)
            .frame(height: 84)
        #endif
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MY JOBS")
                .font(OrbitTheme.mono(12, weight: .semibold))
                .foregroundStyle(OrbitTheme.textLabel)
                .tracking(1.1)

            let runningEntries = mergedRunningEntries()

            if viewModel.statuses.isEmpty {
                Text("No profiles configured")
                    .font(OrbitTheme.mono(11))
                    .foregroundStyle(OrbitTheme.textSecondary)
                    .padding(.vertical, 2)
            } else if runningEntries.isEmpty && viewModel.selectedPendingJobs.isEmpty {
                Text("No active jobs")
                    .font(OrbitTheme.mono(11))
                    .foregroundStyle(OrbitTheme.textSecondary)
                    .padding(.vertical, 2)
            }

            let runningOverflow = max(0, runningEntries.count - maxRunningRows)

            if isRunningExpanded && runningOverflow > 0 {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(runningEntries) { entry in
                            switch entry {
                            case .array(let group):
                                arrayRow(group)
                            case .single(let job):
                                runningRow(job)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            } else {
                let running = Array(runningEntries.prefix(maxRunningRows))
                ForEach(running) { entry in
                    switch entry {
                    case .array(let group):
                        arrayRow(group)
                    case .single(let job):
                        runningRow(job)
                    }
                }
            }

            if runningOverflow > 0 {
                HStack {
                    if !isRunningExpanded {
                        Text("+\(runningOverflow) more running")
                            .font(OrbitTheme.mono(10))
                            .foregroundStyle(OrbitTheme.textTimestamp)
                    }

                    Spacer()

                    Button {
                        isRunningExpanded.toggle()
                    } label: {
                        Text(isRunningExpanded ? "Collapse" : "Expand")
                            .font(OrbitTheme.mono(10))
                            .foregroundStyle(OrbitTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            let pendingJobs = viewModel.selectedPendingJobs
            let pendingOverflow = max(0, pendingJobs.count - maxPendingRows)

            if !pendingJobs.isEmpty {
                Text("PENDING")
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textLabel)
                    .tracking(1.0)
                    .padding(.top, 2)

                if isPendingExpanded && pendingOverflow > 0 {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(pendingJobs, id: \.id) { job in
                                pendingRow(job)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                } else {
                    let pending = Array(pendingJobs.prefix(maxPendingRows))
                    ForEach(pending, id: \.id) { job in
                        pendingRow(job)
                    }
                }

                if pendingOverflow > 0 {
                    HStack {
                        if !isPendingExpanded {
                            Text("+\(pendingOverflow) more pending")
                                .font(OrbitTheme.mono(10))
                                .foregroundStyle(OrbitTheme.textTimestamp)
                        }

                        Spacer()

                        Button {
                            isPendingExpanded.toggle()
                        } label: {
                            Text(isPendingExpanded ? "Collapse" : "Expand")
                                .font(OrbitTheme.mono(10))
                                .foregroundStyle(OrbitTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func runningRow(_ job: JobSnapshot) -> some View {
        let isExpanded = viewModel.expandedRunningJobID == job.id

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                viewModel.toggleRunningJobExpansion(jobID: job.id)
            } label: {
                HStack(spacing: 8) {
                    Text(isExpanded ? "▾" : "▸")
                        .font(OrbitTheme.mono(10, weight: .semibold))
                        .foregroundStyle(OrbitTheme.accent.opacity(0.9))

                    Text(jobDisplayName(job))
                        .font(OrbitTheme.mono(12, weight: .semibold))
                        .foregroundStyle(OrbitTheme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(runningTimeLabel(job))
                        .font(OrbitTheme.mono(11))
                        .foregroundStyle(OrbitTheme.textSecondary)
                        .lineLimit(1)

                    statusBadge(job)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(spacing: 6) {
                    if job.cpus > 0 {
                        metricPill(value: "\(job.cpus)", label: "CPU")
                    }

                    if let memory = runningMemoryValue(job) {
                        metricPill(value: memory, label: "RAM")
                    }

                    if let node = runningNodeValue(job) {
                        neutralPill(node)
                    }

                    if let remaining = remainingTimeLabel(job) {
                        subtleMetricPill(value: remaining, label: "LEFT")
                    }

                    Button {
                        viewModel.selectJob(job)
                    } label: {
                        jobIDPill(job.id)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.leading, Layout.detailInset)
            }

            if isExpanded, let progress = viewModel.progress(job) {
                GeometryReader { geo in
                    let width = max(0, geo.size.width * min(1, max(0, progress)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.11))
                            .frame(height: 2)
                        Capsule()
                            .fill(progressTint(job, progress: progress))
                            .frame(width: width, height: 2)
                    }
                }
                .frame(height: 2)
            }
        }
    }

    private func arrayRow(_ group: OrbitMenuBarViewModel.ArrayRunningGroup) -> some View {
        let isExpanded = viewModel.expandedArrayParentID == group.parentJobID

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                viewModel.toggleArrayExpansion(parentJobID: group.parentJobID)
            } label: {
                HStack(spacing: 8) {
                    Text(isExpanded ? "▾" : "▸")
                        .font(OrbitTheme.mono(10, weight: .semibold))
                        .foregroundStyle(OrbitTheme.accent.opacity(0.9))

                    Text(group.name)
                        .font(OrbitTheme.mono(12, weight: .semibold))
                        .foregroundStyle(OrbitTheme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(group.progressText)
                        .font(OrbitTheme.mono(11, weight: .semibold))
                        .foregroundStyle(OrbitTheme.textSecondary)

                    arrayStatusBadge(group)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Stats row
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(group.done)")
                                    .font(OrbitTheme.mono(20, weight: .semibold))
                                    .foregroundStyle(OrbitTheme.textPrimary)
                                Text(group.expandedTotalText)
                                    .font(OrbitTheme.mono(12))
                                    .foregroundStyle(OrbitTheme.textSecondary)
                            }
                            Text("tasks finished")
                                .font(OrbitTheme.mono(10))
                                .foregroundStyle(OrbitTheme.textTimestamp)
                        }

                        Spacer(minLength: 8)

                        arrayStatColumn(value: "\(group.running)", label: "RUNNING", color: OrbitTheme.array)
                        Spacer(minLength: 8).frame(maxWidth: 16)
                        arrayStatColumn(value: "\(group.pending)", label: "PENDING", color: OrbitTheme.warning)
                    }

                    // Progress bar
                    GeometryReader { geo in
                        let width = max(0, geo.size.width * group.completion)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.11))
                                .frame(height: 2)
                            Capsule()
                                .fill(OrbitTheme.array)
                                .frame(width: width, height: 2)
                        }
                    }
                    .frame(height: 2)

                    // Resource pills
                    if let rep = group.representativeJob {
                        HStack(spacing: 6) {
                            if rep.cpus > 0 {
                                metricPill(value: "\(rep.cpus)", label: "CPU/task")
                            }
                            if let mem = runningMemoryValue(rep) {
                                metricPill(value: mem, label: "/task")
                            }
                            if let limit = rep.timeLimit, limit > 0 {
                                metricPill(value: formatCompactDuration(limit), label: "walltime")
                            }
                            Button {
                                viewModel.selectJob(rep)
                            } label: {
                                jobIDPill(group.parentJobID)
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)
                        }
                    }

                    // Slowest running tasks
                    let topTasks = topLongestRunningTasks(group, limit: 3)
                    if !topTasks.isEmpty {
                        Rectangle()
                            .fill(OrbitTheme.divider)
                            .frame(height: 1)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("SLOWEST RUNNING")
                                .font(OrbitTheme.mono(10, weight: .semibold))
                                .foregroundStyle(OrbitTheme.textLabel)
                                .tracking(0.8)

                            arrayTaskTableHeaderCompact

                            ForEach(Array(topTasks.enumerated()), id: \.element.id) { offset, child in
                                arrayTaskRowCompact(group: group, job: child, fallbackIndex: offset)
                            }

                            let hiddenCount = max(0, group.runningChildren.count - topTasks.count)
                            if hiddenCount > 0 {
                                Text("+\(hiddenCount) more running")
                                    .font(OrbitTheme.mono(9))
                                    .foregroundStyle(OrbitTheme.textTimestamp)
                                    .padding(.top, 1)
                            }
                        }
                    }
                }
                .padding(.leading, Layout.detailInset)
                .padding(.top, 4)
            } else {
                // Collapsed summary line
                HStack(spacing: 8) {
                    Text("\(group.running) running · \(group.pending) pending")
                        .font(OrbitTheme.mono(10))
                        .foregroundStyle(OrbitTheme.textSecondary)

                    Spacer(minLength: 8)

                    if let completionPercent = group.completionPercent {
                        Text("\(completionPercent)%")
                            .font(OrbitTheme.mono(10, weight: .semibold))
                            .foregroundStyle(OrbitTheme.textTimestamp)
                    } else {
                        Text("total unknown")
                            .font(OrbitTheme.mono(9, weight: .semibold))
                            .foregroundStyle(OrbitTheme.textTimestamp)
                    }
                }

                GeometryReader { geo in
                    let width = max(0, geo.size.width * group.completion)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.11))
                            .frame(height: 2)
                        Capsule()
                            .fill(OrbitTheme.array)
                            .frame(width: width, height: 2)
                    }
                }
                .frame(height: 2)
            }
        }
    }

    private func pendingRow(_ job: JobSnapshot) -> some View {
        HStack(spacing: 8) {
            Text(jobDisplayName(job))
                .font(OrbitTheme.mono(11))
                .foregroundStyle(OrbitTheme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(pendingReason(job))
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.textLabel)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .lineLimit(1)
        }
    }

    private var clusterLoadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("CLUSTER LOAD")
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textLabel)
                    .tracking(1.1)

                Spacer(minLength: 8)

                Button {
                    selectedNodePartition = nil
                    viewModel.toggleClusterLoadExpansion()
                } label: {
                    Text(viewModel.isClusterLoadExpanded ? "▾" : "▸")
                        .font(OrbitTheme.mono(12, weight: .semibold))
                        .foregroundStyle(OrbitTheme.accent.opacity(0.9))
                        .frame(width: 18, height: 18, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedStatus == nil)
            }

            ForEach(clusterLoadStatuses, id: \.profile.id) { status in
                let isSelected = status.profile.id == viewModel.selectedStatus?.profile.id

                VStack(alignment: .leading, spacing: 10) {
                    clusterLoadSummaryButton(for: status, isSelected: isSelected)

                    if isSelected && viewModel.isClusterLoadExpanded {
                        nodeDetailsPanel(for: status)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func clusterLoadSummaryButton(for status: ProfileStatus, isSelected: Bool) -> some View {
        Button {
            selectedNodePartition = nil
            if isSelected {
                viewModel.toggleClusterLoadExpansion()
            } else {
                viewModel.selectedProfileID = status.profile.id
                if !viewModel.isClusterLoadExpanded {
                    viewModel.toggleClusterLoadExpansion()
                }
            }
        } label: {
            if isSelected {
                expandedClusterLoadSummary(for: status)
            } else {
                compactClusterLoadSummary(for: status, isSelected: isSelected)
            }
        }
        .buttonStyle(.plain)
    }

    private func compactClusterLoadSummary(for status: ProfileStatus, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(status.profile.displayName)
                .font(OrbitTheme.mono(12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? OrbitTheme.textPrimary : OrbitTheme.textSecondary)
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(status.profile.displayName)

            thinLoadBar(percent: status.clusterLoad?.cpuLoadPercent, height: 2)

            Text(clusterPercentText(status.clusterLoad))
                .font(OrbitTheme.mono(12, weight: .semibold))
                .foregroundStyle(status.clusterLoad == nil ? OrbitTheme.textTimestamp : (isSelected ? OrbitTheme.textPrimary : OrbitTheme.textSecondary))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)

            Text(isSelected && viewModel.isClusterLoadExpanded ? "▾" : "▸")
                .font(OrbitTheme.mono(11, weight: .semibold))
                .foregroundStyle(OrbitTheme.accent.opacity(0.9))
                .frame(width: 10, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private func expandedClusterLoadSummary(for status: ProfileStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(status.profile.displayName)
                    .font(OrbitTheme.mono(13, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status.profile.displayName)

                Spacer(minLength: 8)

                Text(clusterPercentText(status.clusterLoad))
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(status.clusterLoad == nil ? OrbitTheme.textTimestamp : OrbitTheme.accent)
                    .monospacedDigit()
            }

            thinLoadBar(percent: status.clusterLoad?.cpuLoadPercent, height: 6)

            HStack(spacing: 8) {
                Text(clusterAllocatedFreeText(status.clusterLoad))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(clusterAllocatedFreeHelp(status.clusterLoad))

                Spacer(minLength: 8)

                Text(clusterTotalCoresText(status.clusterLoad))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(clusterTotalCoresHelp(status.clusterLoad))
            }
            .font(OrbitTheme.mono(10))
            .foregroundStyle(OrbitTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private func nodeDetailsPanel(for status: ProfileStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(OrbitTheme.divider)
                .frame(height: 1)

            HStack {
                Text("NODE DETAILS")
                    .font(OrbitTheme.mono(10, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textLabel)
                    .tracking(0.8)

                Spacer(minLength: 8)

                Button(viewModel.isLoadingNodeInventory ? "refreshing…" : "refresh") {
                    viewModel.refreshNodeInventory()
                }
                .buttonStyle(.plain)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(viewModel.isLoadingNodeInventory ? OrbitTheme.textTimestamp : OrbitTheme.accent)
                .disabled(viewModel.isLoadingNodeInventory)
            }

            clusterKPIBlock(for: status)

            if !nodePartitionChips.isEmpty {
                partitionChipScroller
            }

            if viewModel.isLoadingNodeInventory && viewModel.selectedNodeRows.isEmpty {
                clusterLoadEmptyMessage("Loading node inventory…")
            } else if viewModel.selectedNodeRows.isEmpty {
                clusterLoadEmptyMessage("No node details available yet")
            } else if filteredNodeRows.isEmpty {
                clusterLoadEmptyMessage("No nodes in this partition")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    nodeListHeader

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredNodeRows) { row in
                                nodeDetailRow(row)
                            }
                        }
                    }
                    .frame(maxHeight: 188)
                    .clipped()
                }
            }
        }
    }

    private func clusterLoadEmptyMessage(_ message: String) -> some View {
        Text(message)
            .font(OrbitTheme.mono(10))
            .foregroundStyle(OrbitTheme.textTimestamp)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                updater.toggleExpanded()
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(updateTint.opacity(0.14))
                            .frame(width: 25, height: 25)

                        if updater.isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(updateTint)
                        } else {
                            Image(systemName: updateIconName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(updateTint)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateHeadline)
                            .font(OrbitTheme.mono(10, weight: .semibold))
                            .foregroundStyle(OrbitTheme.textPrimary)
                            .lineLimit(1)

                        if let detail = updater.statusDetail {
                            Text(detail)
                                .font(OrbitTheme.sans(10))
                                .foregroundStyle(OrbitTheme.textSecondary)
                                .lineLimit(updater.isExpanded ? 2 : 1)
                        }
                    }

                    Spacer(minLength: 6)

                    if updater.phase == .available && !updater.isExpanded {
                        Text("VIEW")
                            .font(OrbitTheme.mono(8, weight: .semibold))
                            .foregroundStyle(OrbitTheme.accent)
                            .tracking(0.8)
                    }

                    Image(systemName: updater.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(OrbitTheme.textLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)

            if updater.isExpanded {
                Rectangle()
                    .fill(updateTint.opacity(0.14))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    if let releaseNotes = updater.releaseNotes,
                       !releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ScrollView {
                            Text(markdownReleaseNotes(releaseNotes))
                                .font(OrbitTheme.sans(11))
                                .foregroundStyle(OrbitTheme.textSecondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 4)
                        }
                        .frame(maxHeight: 175)
                        .padding(10)
                        .background(Color.black.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.055), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else if let error = updater.releaseNotesError {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(OrbitTheme.textLabel)
                            Text(error)
                                .font(OrbitTheme.sans(10))
                                .foregroundStyle(OrbitTheme.textSecondary)
                        }
                    } else if updater.phase == .available {
                        Text("Release notes are loading…")
                            .font(OrbitTheme.sans(10))
                            .foregroundStyle(OrbitTheme.textLabel)
                    }

                    if let progress = updater.progress {
                        VStack(alignment: .leading, spacing: 5) {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.07))
                                    Capsule()
                                        .fill(updateTint)
                                        .frame(width: proxy.size.width * min(1, max(0, progress)))
                                }
                            }
                            .frame(height: 4)

                            Text("\(Int((progress * 100).rounded()))%")
                                .font(OrbitTheme.mono(9))
                                .foregroundStyle(OrbitTheme.textTimestamp)
                        }
                    }

                    updateActions
                }
                .padding(10)
            }
        }
        .background(updateTint.opacity(0.065))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(updateTint.opacity(0.20), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var updateActions: some View {
        switch updater.phase {
        case .available:
            if updater.isInformationOnlyUpdate {
                Button("Open Release Page") {
                    updater.openInformationOnlyUpdate()
                }
                .buttonStyle(OrbitUpdatePrimaryButtonStyle())
            } else {
                HStack(spacing: 7) {
                    Button("Download & Install") {
                        updater.downloadAndInstallUpdate()
                    }
                    .buttonStyle(OrbitUpdatePrimaryButtonStyle())

                    Button("Later") {
                        updater.remindLater()
                    }
                    .buttonStyle(OrbitUpdateGhostButtonStyle())
                }

                HStack(spacing: 12) {
                    if updater.releasePageURL != nil {
                        Button("View release on GitHub ↗") {
                            updater.openReleasePage()
                        }
                        .buttonStyle(.plain)
                        .font(OrbitTheme.mono(9, weight: .semibold))
                        .foregroundStyle(OrbitTheme.accent)
                    }

                    Button("Skip this version") {
                        updater.skipThisVersion()
                    }
                    .buttonStyle(.plain)
                    .font(OrbitTheme.mono(9))
                    .foregroundStyle(OrbitTheme.textLabel)
                }
            }

        case .readyToInstall:
            HStack(spacing: 7) {
                Button("Install & Relaunch") {
                    updater.installAndRelaunch()
                }
                .buttonStyle(OrbitUpdatePrimaryButtonStyle())

                Button("Later") {
                    updater.remindLater()
                }
                .buttonStyle(OrbitUpdateGhostButtonStyle())
            }

        case .checking, .downloading:
            Button("Cancel") {
                updater.cancelCurrentOperation()
            }
            .buttonStyle(OrbitUpdateGhostButtonStyle())

        case .installing:
            Button("Try Quit Again") {
                updater.retryTerminatingApplication()
            }
            .buttonStyle(OrbitUpdateGhostButtonStyle())

        case .upToDate, .failed:
            Button("Dismiss") {
                updater.dismissStatus()
            }
            .buttonStyle(OrbitUpdateGhostButtonStyle())

        case .idle, .extracting:
            EmptyView()
        }
    }

    private var updateHeadline: String {
        switch updater.phase {
        case .idle:
            return "Software Update"
        case .checking:
            return "Checking for updates"
        case .available:
            return updater.availableVersion.map { "Orbit \($0) is available" } ?? "Update available"
        case .downloading:
            return "Downloading update"
        case .extracting:
            return "Verifying update"
        case .readyToInstall:
            return "Ready to relaunch"
        case .installing:
            return "Installing update"
        case .upToDate:
            return "Orbit is up to date"
        case .failed:
            return "Update could not be completed"
        }
    }

    private var updateIconName: String {
        switch updater.phase {
        case .available: return "arrow.down.circle.fill"
        case .readyToInstall: return "checkmark.circle.fill"
        case .upToDate: return "checkmark"
        case .failed: return "exclamationmark"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var updateTint: Color {
        switch updater.phase {
        case .readyToInstall, .upToDate:
            return OrbitTheme.success
        case .failed:
            return OrbitTheme.danger
        default:
            return OrbitTheme.accent
        }
    }

    private func markdownReleaseNotes(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if updater.shouldShowStatus {
                updateSection
            }

            HStack(spacing: 10) {
                Text(viewModel.selectedUpdatedFooterText)
                    .font(OrbitTheme.mono(11))
                    .foregroundStyle(viewModel.selectedIsStale ? OrbitTheme.warning.opacity(0.9) : OrbitTheme.textTimestamp)

                Spacer(minLength: 8)

                Button("Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.plain)
                .font(OrbitTheme.mono(12))
                .foregroundStyle(OrbitTheme.textSecondary)

                if viewModel.selectedGrafanaURL != nil {
                    Button("Open Grafana ↗") {
                        viewModel.openGrafana()
                    }
                    .buttonStyle(.plain)
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(OrbitTheme.accent)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(OrbitTheme.divider)
            .frame(height: 1)
    }

    // MARK: - Data helpers

    private var isNaturallyIdle: Bool {
        !viewModel.statuses.isEmpty && !viewModel.selectedHasActiveJobs
    }

    private var shouldShowStatsScreen: Bool {
        isNaturallyIdle || (forceShowStats && canToggleStatsScreen)
    }

    private var canToggleStatsScreen: Bool {
        !viewModel.statuses.isEmpty && viewModel.selectedHasActiveJobs
    }

    private var idleViewData: OrbitIdleStateView.Data {
        let selected = viewModel.selectedStatus
        let weekly = viewModel.selectedWeeklyUsage
        let bars = weekBars(from: weekly)

        let statusTitle: String = isNaturallyIdle ? "No active jobs" : "Usage stats"
        let statusTrailingText: String? = isNaturallyIdle ? "idle since \(idleSinceText)" : "last 7 days"
        let statusDotColor: Color = isNaturallyIdle ? OrbitTheme.textTimestamp : OrbitTheme.accent.opacity(0.9)

        return OrbitIdleStateView.Data(
            statusTitle: statusTitle,
            statusTrailingText: statusTrailingText,
            statusDotColor: statusDotColor,
            loadPercent: selected?.clusterLoad?.cpuLoadPercent,
            loadPhraseRanges: loadPhraseRanges,
            loadPhraseFallback: "Cluster load unavailable right now.",
            weekRangeText: weekRangeText(for: weekly),
            weeklyBars: bars,
            totalJobsThisWeek: weekly?.totalJobs,
            totalCPUHoursThisWeek: weekly?.totalCPUHours,
            estimatedCostThisWeek: viewModel.selectedEstimatedCostThisWeek,
            cpuHourRate: viewModel.cpuHourRatePerHour
        )
    }

    private var idleSinceText: String {
        guard let idleSince = viewModel.selectedIdleSince else { return "—" }
        return Formatters.idleSince.string(from: idleSince)
    }

    private var loadPhraseRanges: [OrbitIdleStateView.LoadPhraseRange] {
        [
            OrbitIdleStateView.LoadPhraseRange(
                lowerBound: 0,
                upperBound: 20,
                options: [
                    "The cluster is yours to take.",
                    "Plenty of headroom right now.",
                    "Feels quiet. Great time to run something heavy.",
                    "Cluster is quiet. The scheduler is almost suspicious.",
                    "So much free capacity it feels illegal.",
                    "Great time to submit before everyone wakes up.",
                    "Queue is basically decorative right now.",
                    "It’s calm. Enjoy this rare moment of peace."
                ]
            ),
            OrbitIdleStateView.LoadPhraseRange(
                lowerBound: 20,
                upperBound: 50,
                options: [
                    "Light traffic. Good time to submit.",
                    "Queue looks calm. Your job should start soon.",
                    "Moderate load. This is a good submission window.",
                    "Light traffic. Your job might even start on time.",
                    "Some load, but still no need for queue therapy.",
                    "Moderate usage. Scheduler still answers politely.",
                    "A reasonable moment to submit for once.",
                    "Not empty, not chaotic — surprisingly balanced."
                ]
            ),
            OrbitIdleStateView.LoadPhraseRange(
                lowerBound: 50,
                upperBound: 80,
                options: [
                    "Busy. Jobs may queue for a bit.",
                    "Half the cluster is grinding. You'll get in.",
                    "It's busy in there. Submit and grab a coffee.",
                    "Mild chaos. Your job will find a slot.",
                    "Busy now. Queue time is no longer a rumor.",
                    "Cluster is warming up. Patience becomes a feature.",
                    "Half to mostly full — instant start not guaranteed.",
                    "Things are moving, just not quickly enough.",
                    "You’ll get in. Eventually. Probably."
                ]
            ),
            OrbitIdleStateView.LoadPhraseRange(
                lowerBound: 80,
                upperBound: nil,
                options: [
                    "Queue is packed. Consider submitting overnight.",
                    "Good luck getting in the queue.",
                    "Someone's been busy. So has everyone else.",
                    "The queue is a battlefield right now.",
                    "Might be a while. The cluster is very popular today.",
                    "Everyone had the same idea. Good luck.",
                    "Queue is packed. Bold time to submit.",
                    "Ah yes, perfect timing — said no scheduler ever.",
                    "The cluster is doing leg day. Expect a wait.",
                    "It’s basically Black Friday at the queue.",
                    "If this starts instantly, buy a lottery ticket.",
                    "Peak chaos mode enabled. Patience recommended."
                ]
            )
        ]
    }

    private func weekBars(from weekly: WeeklyUsageSummary?) -> [OrbitIdleStateView.DayBar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        let weekStart = weekly?.weekStart ?? calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()

        let valuesByDay: [Date: Double] = {
            guard let weekly else { return [:] }
            return Dictionary(uniqueKeysWithValues: weekly.dailyCPUHours.map { (calendar.startOfDay(for: $0.date), $0.cpuHours) })
        }()

        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            let day = calendar.startOfDay(for: date)
            let label = Formatters.weekdayShort.string(from: day)
            return OrbitIdleStateView.DayBar(
                id: label + "-\(offset)",
                shortLabel: label,
                cpuHours: weekly == nil ? nil : valuesByDay[day] ?? 0,
                isToday: calendar.isDateInToday(day)
            )
        }
    }

    private func weekRangeText(for weekly: WeeklyUsageSummary?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        let start = weekly?.weekStart ?? calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let endExclusive = weekly?.weekEnd ?? calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let end = calendar.date(byAdding: .day, value: -1, to: endExclusive) ?? endExclusive

        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(Formatters.monthDay.string(from: start)) – \(Formatters.dayOnly.string(from: end))"
        }
        return "\(Formatters.monthDay.string(from: start)) – \(Formatters.monthDay.string(from: end))"
    }

    private func mergedRunningEntries() -> [RunningEntry] {
        let arrays = viewModel.selectedArrayGroups.map { RunningEntry.array($0) }
        let singles = viewModel.selectedSingleRunningJobs.map { RunningEntry.single($0) }
        let all = arrays + singles

        return all.sorted { lhs, rhs in
            let lhsIsArray = lhs.isArray
            let rhsIsArray = rhs.isArray
            if lhsIsArray != rhsIsArray { return lhsIsArray }
            return false // preserve relative order within same kind
        }
    }

    private var clusterLoadStatuses: [ProfileStatus] {
        viewModel.statuses.sorted {
            $0.profile.displayName.localizedCaseInsensitiveCompare($1.profile.displayName) == .orderedAscending
        }
    }

    private var filteredNodeRows: [OrbitMenuBarViewModel.NodeLoadRow] {
        guard let selectedNodePartition else { return viewModel.selectedNodeRows }
        return viewModel.selectedNodeRows.filter { row in
            row.node.partitions.contains { $0.caseInsensitiveCompare(selectedNodePartition) == .orderedSame }
        }
    }

    private var nodePartitionChips: [(name: String?, title: String, count: Int)] {
        let rows = viewModel.selectedNodeRows
        guard !rows.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        for row in rows {
            let partitions = row.node.partitions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for partition in partitions {
                counts[partition, default: 0] += 1
            }
        }

        var chips: [(name: String?, title: String, count: Int)] = [(nil, "all", rows.count)]
        let sorted = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
        chips.append(contentsOf: sorted.map { (Optional($0.key), partitionChipTitle($0.key), $0.value) })

        if let selectedNodePartition,
           !chips.contains(where: { $0.name == selectedNodePartition }),
           let selectedCount = counts[selectedNodePartition] {
            chips.append((selectedNodePartition, partitionChipTitle(selectedNodePartition), selectedCount))
        }

        return chips
    }

    private var partitionChipScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(nodePartitionChips.enumerated()), id: \.offset) { _, chip in
                    partitionChip(name: chip.name, title: chip.title, count: chip.count)
                }
            }
        }
    }

    private func clusterKPIBlock(for status: ProfileStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let load = status.clusterLoad
            clusterStatRow(
                label: "CPU",
                used: load?.allocatedCPUs,
                total: load?.totalCPUs,
                percent: load?.cpuLoadPercent
            )

            clusterStatRow(
                label: "NODES",
                used: load?.allocatedNodes,
                total: load?.totalNodes,
                percent: load.map { nodeLoadPercent($0) }
            )

            if viewModel.selectedTotalGPUs > 0 {
                clusterStatRow(
                    label: "GPU",
                    used: viewModel.selectedAllocatedGPUs,
                    total: viewModel.selectedTotalGPUs,
                    percent: gpuLoadPercent
                )
            }

            HStack(spacing: 10) {
                Text("JOBS")
                    .font(OrbitTheme.mono(10, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textSecondary)
                    .tracking(0.6)
                    .frame(width: 44, alignment: .leading)

                HStack(spacing: 16) {
                    jobCountMetric(value: status.runningJobs, label: "running", accent: true)
                    jobCountMetric(value: status.pendingJobs, label: "queued", accent: false)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 4)
        }
    }

    private func clusterStatRow(label: String, used: Int?, total: Int?, percent: Double?) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.textSecondary)
                .tracking(0.6)
                .frame(width: 44, alignment: .leading)

            thinLoadBar(percent: percent, height: 4)

            Text(capacityFractionText(used: used, total: total))
                .font(OrbitTheme.mono(11))
                .foregroundStyle(OrbitTheme.textPrimary.opacity(0.9))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .help(capacityFractionHelp(used: used, total: total))
                .frame(width: 70, alignment: .trailing)

            Text(percentText(percent))
                .font(OrbitTheme.mono(10.5, weight: .semibold))
                .foregroundStyle(percent == nil ? OrbitTheme.textTimestamp : OrbitTheme.accent)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func jobCountMetric(value: Int, label: String, accent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(compactCount(value))
                .font(OrbitTheme.mono(11, weight: .semibold))
                .foregroundStyle(accent ? OrbitTheme.accent : OrbitTheme.textPrimary.opacity(0.9))
                .monospacedDigit()
                .lineLimit(1)
                .help(groupedCount(value))

            Text(label)
                .font(OrbitTheme.mono(10))
                .foregroundStyle(OrbitTheme.textLabel)
                .lineLimit(1)
        }
    }

    private func partitionChip(name: String?, title: String, count: Int) -> some View {
        let isSelected = selectedNodePartition == name
        return Button {
            selectedNodePartition = name
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(compactCount(count))
                    .foregroundStyle(isSelected ? OrbitTheme.accent.opacity(0.75) : OrbitTheme.textLabel)
                    .lineLimit(1)
                    .help(groupedCount(count))
            }
            .font(OrbitTheme.mono(10, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? OrbitTheme.accent : OrbitTheme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: 112)
            .background(isSelected ? OrbitTheme.accent.opacity(0.12) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isSelected ? OrbitTheme.accent.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(name ?? "All nodes")
        }
        .buttonStyle(.plain)
    }

    private func thinLoadBar(percent: Double?, height: CGFloat) -> some View {
        GeometryReader { geo in
            let progress = max(0, min(1, (percent ?? 0) / 100.0))
            let width = geo.size.width * progress

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: max(1, height / 2), style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(height: height)

                RoundedRectangle(cornerRadius: max(1, height / 2), style: .continuous)
                    .fill(percent == nil ? OrbitTheme.textTimestamp.opacity(0.35) : OrbitTheme.accent)
                    .frame(width: width, height: height)
            }
        }
        .frame(height: height)
    }

    private func partitionChipTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        return trimmed.count > 14 ? String(trimmed.prefix(13)) + "…" : trimmed
    }

    private func clusterPercentText(_ load: ClusterLoad?) -> String {
        percentText(load?.cpuLoadPercent)
    }

    private func percentText(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return String(format: "%.0f%%", max(0, min(999, percent)))
    }

    private func nodeLoadPercent(_ load: ClusterLoad) -> Double {
        guard load.totalNodes > 0 else { return 0 }
        return Double(load.allocatedNodes) / Double(load.totalNodes) * 100.0
    }

    private var gpuLoadPercent: Double? {
        let total = viewModel.selectedTotalGPUs
        guard total > 0, let used = viewModel.selectedAllocatedGPUs else { return nil }
        return Double(max(0, min(used, total))) / Double(total) * 100.0
    }

    private func clusterAllocatedFreeText(_ load: ClusterLoad?) -> String {
        guard let load, load.totalCPUs > 0 else { return "load unavailable" }
        let allocated = max(0, min(load.allocatedCPUs, load.totalCPUs))
        let free = max(0, load.totalCPUs - allocated)
        return "\(compactCount(allocated)) alloc · \(compactCount(free)) free"
    }

    private func clusterAllocatedFreeHelp(_ load: ClusterLoad?) -> String {
        guard let load, load.totalCPUs > 0 else { return "Cluster load unavailable" }
        let allocated = max(0, min(load.allocatedCPUs, load.totalCPUs))
        let free = max(0, load.totalCPUs - allocated)
        return "\(groupedCount(allocated)) allocated · \(groupedCount(free)) free"
    }

    private func clusterTotalCoresText(_ load: ClusterLoad?) -> String {
        guard let load, load.totalCPUs > 0 else { return "— cores" }
        return "\(compactCount(load.totalCPUs)) cores"
    }

    private func clusterTotalCoresHelp(_ load: ClusterLoad?) -> String {
        guard let load, load.totalCPUs > 0 else { return "Total cores unavailable" }
        return "\(groupedCount(load.totalCPUs)) cores"
    }

    private func capacityFractionText(used: Int?, total: Int?) -> String {
        guard let used, let total, total > 0 else { return "—" }
        return "\(compactCount(max(0, min(used, total))))/\(compactCount(total))"
    }

    private func capacityFractionHelp(used: Int?, total: Int?) -> String {
        guard let used, let total, total > 0 else { return "Capacity unavailable" }
        return "\(groupedCount(max(0, min(used, total)))) / \(groupedCount(total))"
    }

    private func compactCount(_ value: Int) -> String {
        let safe = max(0, value)
        if safe >= 1_000_000 {
            return String(format: "%.1fM", Double(safe) / 1_000_000.0)
        }
        if safe >= 10_000 {
            return String(format: "%.0fK", Double(safe) / 1_000.0)
        }
        return "\(safe)"
    }

    private func groupedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Table layouts

    private enum NodeTableLayout {
        static let dot: CGFloat = 8
        static let node: CGFloat = 52
        static let state: CGFloat = 50
        static let cpu: CGFloat = 44
        static let ram: CGFloat = 52
        static let gpu: CGFloat = 28
        static let part: CGFloat = 56
    }

    private var nodeListHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("")
                    .frame(width: NodeTableLayout.dot, alignment: .leading)
                Text("NODE")
                    .frame(width: NodeTableLayout.node, alignment: .leading)
                Text("STATE")
                    .frame(width: NodeTableLayout.state, alignment: .leading)
                Text("CPU")
                    .frame(width: NodeTableLayout.cpu, alignment: .center)
                Text("RAM/GB")
                    .frame(width: NodeTableLayout.ram, alignment: .center)
                Text("GPU")
                    .frame(width: NodeTableLayout.gpu, alignment: .center)
                Text("PART")
                    .frame(width: NodeTableLayout.part, alignment: .center)
            }
            .font(OrbitTheme.mono(9, weight: .semibold))
            .foregroundStyle(OrbitTheme.textTimestamp)
            .tracking(0.9)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.035))
                .frame(height: 0.5)
        }
    }

    private func nodeDetailRow(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(nodeStateDotTint(row))
                .frame(width: 6, height: 6)
                .frame(width: NodeTableLayout.dot, alignment: .leading)

            Text(row.name)
                .font(OrbitTheme.mono(11))
                .foregroundStyle(OrbitTheme.textPrimary.opacity(0.88))
                .frame(width: NodeTableLayout.node, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.name)

            Text(nodeStateLabel(row))
                .font(OrbitTheme.mono(10))
                .foregroundStyle(nodeStatePresentation(row).tint)
                .tracking(0.4)
                .frame(width: NodeTableLayout.state, alignment: .leading)
                .lineLimit(1)
                .help(row.state)

            Text(row.cpuText)
                .font(OrbitTheme.mono(10))
                .foregroundStyle(nodeCPUTextTint(row))
                .monospacedDigit()
                .frame(width: NodeTableLayout.cpu, alignment: .center)
                .lineLimit(1)
                .help(row.cpuText)

            Text(memoryUsageGBText(row))
                .font(OrbitTheme.mono(10))
                .foregroundStyle(nodeMemoryTextTint(row))
                .monospacedDigit()
                .frame(width: NodeTableLayout.ram, alignment: .center)
                .lineLimit(1)
                .help(memoryUsageGBText(row))

            Text(gpuCountText(row))
                .font(OrbitTheme.mono(10))
                .foregroundStyle(nodeGPUTextTint(row))
                .monospacedDigit()
                .frame(width: NodeTableLayout.gpu, alignment: .center)
                .lineLimit(1)
                .help(gpuCountText(row))

            partitionTag(for: row)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.035))
                .frame(height: 0.5)
        }
    }

    private func partitionTag(for row: OrbitMenuBarViewModel.NodeLoadRow) -> some View {
        Text(primaryPartitionLabel(row) ?? "—")
            .font(OrbitTheme.mono(9))
            .foregroundStyle(OrbitTheme.textSecondary.opacity(0.75))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: NodeTableLayout.part - 12, alignment: .center)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(OrbitTheme.mutedFill)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .frame(width: NodeTableLayout.part, alignment: .center)
            .help(row.node.partitions.joined(separator: ", "))
    }

    private func nodeStateLabel(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> String {
        nodeStatePresentation(row).label
    }

    private func nodeStateDotTint(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> Color {
        nodeStatePresentation(row).tint
    }

    private func nodeStatePresentation(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> (label: String, tint: Color) {
        let state = row.state.uppercased()
        let totalCPU = max(0, row.node.totalCPUs)
        let allocatedCPU = max(0, min(row.node.allocatedCPUs, totalCPU))

        if state.contains("DOWN") || state.contains("FAIL") || state.contains("INVAL") {
            return ("down", OrbitTheme.danger)
        }

        if state.contains("DRAIN") {
            return ("drain", OrbitTheme.warning)
        }

        if state.contains("MAINT") {
            return ("maint", OrbitTheme.warning)
        }

        if state.contains("RESV") || state.contains("RESERVED") {
            return ("reserved", OrbitTheme.array.opacity(0.95))
        }

        if state.contains("MIX") {
            return ("busy", OrbitTheme.warning)
        }

        if state.contains("ALLOC") {
            let label = totalCPU > 0 && allocatedCPU >= totalCPU ? "full" : "busy"
            return (label, OrbitTheme.accent)
        }

        if state.contains("COMPLET") {
            return ("busy", OrbitTheme.accent.opacity(0.85))
        }

        if state.contains("IDLE") {
            return ("idle", OrbitTheme.textTimestamp.opacity(0.95))
        }

        return (compactNodeState(row.state).lowercased(), OrbitTheme.textTimestamp.opacity(0.65))
    }

    private func nodeCPUTextTint(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> Color {
        let total = max(0, row.node.totalCPUs)
        let used = max(0, min(row.node.allocatedCPUs, total))
        guard total > 0 else { return OrbitTheme.textTimestamp }
        if used == 0 { return OrbitTheme.textTimestamp }
        if used >= total { return OrbitTheme.accent }
        return OrbitTheme.textSecondary
    }

    private func nodeMemoryTextTint(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> Color {
        guard row.node.memoryMB != nil else { return OrbitTheme.textTimestamp }
        return OrbitTheme.textSecondary
    }

    private func nodeGPUTextTint(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> Color {
        guard let total = row.gpuTotalCount, total > 0 else { return OrbitTheme.textTimestamp }
        let used = max(0, min(row.gpuUsedCount ?? 0, total))
        if used >= total { return OrbitTheme.accent }
        return OrbitTheme.textSecondary
    }

}
