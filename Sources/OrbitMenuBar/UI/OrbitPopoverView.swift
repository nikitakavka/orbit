import SwiftUI
#if canImport(Charts)
import Charts
#endif
import OrbitCore

struct OrbitPopoverView: View {
    @ObservedObject var viewModel: OrbitMenuBarViewModel
    @ObservedObject var presentation: OrbitMenuBarPresentationModel
    let onOpenSettings: () -> Void

    @State private var forceShowStats: Bool = false
    @State private var isRunningExpanded: Bool = false
    @State private var isPendingExpanded: Bool = false

    private let maxRunningRows = 3
    private let maxPendingRows = 3

    enum Layout {
        static let width: CGFloat = 380
        static let maxHeight: CGFloat = 860
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

                    Text("\(group.done)/\(group.total)")
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
                                Text("/ \(group.total)")
                                    .font(OrbitTheme.mono(12))
                                    .foregroundStyle(OrbitTheme.textSecondary)
                            }
                            Text("tasks completed")
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

                    Text("\(group.completionPercent)%")
                        .font(OrbitTheme.mono(10, weight: .semibold))
                        .foregroundStyle(OrbitTheme.textTimestamp)
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
            HStack {
                Text("CLUSTER LOAD (CPU)")
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textLabel)
                    .tracking(1.1)

                Spacer()
            }

            ForEach(clusterLoadStatuses, id: \.profile.id) { status in
                let isSelected = status.profile.id == viewModel.selectedStatus?.profile.id

                Button {
                    if isSelected {
                        viewModel.toggleClusterLoadExpansion()
                    } else {
                        viewModel.selectedProfileID = status.profile.id
                        if !viewModel.isClusterLoadExpanded {
                            viewModel.toggleClusterLoadExpansion()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(status.profile.displayName)
                            .font(OrbitTheme.mono(12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? OrbitTheme.textPrimary : OrbitTheme.textSecondary)
                            .frame(width: 72, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(status.profile.displayName)

                        GeometryReader { geo in
                            let progress = max(0, min(1, (status.clusterLoad?.cpuLoadPercent ?? 0) / 100.0))
                            let width = geo.size.width * progress

                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.10))
                                    .frame(height: 2)

                                Capsule()
                                    .fill(loadTint(status.clusterLoad?.cpuLoadPercent ?? 0))
                                    .frame(width: width, height: 2)
                            }
                        }
                        .frame(height: 2)

                        HStack(spacing: 4) {
                            if let load = status.clusterLoad {
                                Text(String(format: "%.0f%%", load.cpuLoadPercent))
                                    .font(OrbitTheme.mono(12, weight: .semibold))
                                    .foregroundStyle(isSelected ? OrbitTheme.textPrimary : OrbitTheme.textSecondary)
                            } else {
                                Text("—")
                                    .font(OrbitTheme.mono(12, weight: .semibold))
                                    .foregroundStyle(OrbitTheme.textTimestamp)
                            }

                            Text(isSelected && viewModel.isClusterLoadExpanded ? "▾" : "▸")
                                .font(OrbitTheme.mono(11, weight: .semibold))
                                .foregroundStyle(OrbitTheme.accent.opacity(0.9))
                        }
                        .frame(width: 44, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if viewModel.isClusterLoadExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle()
                        .fill(OrbitTheme.divider)
                        .frame(height: 1)

                    HStack {
                        Text("NODE DETAILS")
                            .font(OrbitTheme.mono(10, weight: .semibold))
                            .foregroundStyle(OrbitTheme.textLabel)
                        Spacer()
                        Button(viewModel.isLoadingNodeInventory ? "refreshing…" : "refresh") {
                            viewModel.refreshNodeInventory()
                        }
                        .buttonStyle(.plain)
                        .font(OrbitTheme.mono(10, weight: .semibold))
                        .foregroundStyle(OrbitTheme.accent)
                        .disabled(viewModel.isLoadingNodeInventory)
                    }

                    clusterCapacitySummary

                    if let partitionText = selectedPartitionSummaryText {
                        Text("Partitions: \(partitionText)")
                            .font(OrbitTheme.mono(9))
                            .foregroundStyle(OrbitTheme.textTimestamp)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(selectedPartitionSummaryTooltip ?? "")
                    }

                    if viewModel.isLoadingNodeInventory && viewModel.selectedNodeRows.isEmpty {
                        Text("Loading node inventory…")
                            .font(OrbitTheme.mono(10))
                            .foregroundStyle(OrbitTheme.textTimestamp)
                    } else if viewModel.selectedNodeRows.isEmpty {
                        Text("No node details available yet")
                            .font(OrbitTheme.mono(10))
                            .foregroundStyle(OrbitTheme.textTimestamp)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            nodeListHeader

                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(viewModel.selectedNodeRows) { row in
                                        nodeDetailRow(row)
                                    }
                                }
                            }
                            .frame(maxHeight: 104)
                            .clipped()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = viewModel.availableUpdateNotice {
                HStack(spacing: 8) {
                    Text("Update available: \(notice.versionTag)")
                        .font(OrbitTheme.mono(10, weight: .semibold))
                        .foregroundStyle(OrbitTheme.accent)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Button("Open") {
                        viewModel.openAvailableUpdateReleasePage()
                    }
                    .buttonStyle(.plain)
                    .font(OrbitTheme.mono(10, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textPrimary)

                    Button {
                        viewModel.dismissAvailableUpdateNotice()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(OrbitTheme.textSecondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(OrbitTheme.accent.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(OrbitTheme.accent.opacity(0.22), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    private var clusterCapacitySummary: some View {
        HStack(spacing: 6) {
            capacityPill(title: "CPU", value: selectedCPUCapacityText)

            if let gpuText = selectedGPUCapacityText {
                capacityPill(title: "GPU", value: gpuText)
            }

            capacityPill(title: "NODES", value: selectedNodeCapacityText)
            capacityPill(title: "PART", value: "\(viewModel.selectedPartitions.count)")

            Spacer(minLength: 0)
        }
    }

    private var selectedCPUCapacityText: String {
        guard let load = viewModel.selectedStatus?.clusterLoad else { return "—" }
        return "\(load.allocatedCPUs)/\(load.totalCPUs)"
    }

    private var selectedNodeCapacityText: String {
        guard let load = viewModel.selectedStatus?.clusterLoad else { return "—" }
        return "\(load.allocatedNodes)/\(load.totalNodes)"
    }

    private var selectedGPUCapacityText: String? {
        let total = viewModel.selectedTotalGPUs
        guard total > 0 else { return nil }

        if let used = viewModel.selectedAllocatedGPUs {
            return "\(used)/\(total)"
        }

        return "\(total)"
    }

    private var selectedPartitionSummaryText: String? {
        let partitions = viewModel.selectedPartitions
        guard !partitions.isEmpty else { return nil }

        let visible = partitions.prefix(3).map { truncateTail($0, maxLength: 18) }
        var summary = visible.joined(separator: ", ")

        if partitions.count > 3 {
            summary += " +\(partitions.count - 3)"
        }

        return truncateTail(summary, maxLength: 58)
    }

    private var selectedPartitionSummaryTooltip: String? {
        let partitions = viewModel.selectedPartitions
        guard !partitions.isEmpty else { return nil }
        return partitions.joined(separator: ", ")
    }

    private func truncateTail(_ value: String, maxLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max(1, maxLength) else { return trimmed }
        let prefixCount = max(1, maxLength - 3)
        return String(trimmed.prefix(prefixCount)) + "..."
    }

    @ViewBuilder
    private func capacityPill(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(OrbitTheme.mono(9, weight: .semibold))
                .foregroundStyle(OrbitTheme.textTimestamp)
            Text(value)
                .font(OrbitTheme.mono(9, weight: .semibold))
                .foregroundStyle(OrbitTheme.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(OrbitTheme.mutedFill)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Table layouts

    private enum NodeTableLayout {
        static let node: CGFloat = 84
        static let state: CGFloat = 56
        static let cpu: CGFloat = 34
        static let ram: CGFloat = 48
        static let gpu: CGFloat = 28
        static let part: CGFloat = 62
    }

    private var nodeListHeader: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("NODE")
                    .frame(width: NodeTableLayout.node, alignment: .leading)
                Text("STATE")
                    .frame(width: NodeTableLayout.state, alignment: .center)
                Text("CPU")
                    .frame(width: NodeTableLayout.cpu, alignment: .center)
                Text("RAM GB")
                    .frame(width: NodeTableLayout.ram, alignment: .center)
                Text("GPU")
                    .frame(width: NodeTableLayout.gpu, alignment: .center)
                Text("PART")
                    .frame(width: NodeTableLayout.part, alignment: .leading)
            }
            .font(OrbitTheme.mono(9, weight: .semibold))
            .foregroundStyle(OrbitTheme.textTimestamp)

            Rectangle()
                .fill(OrbitTheme.divider)
                .frame(height: 1)
        }
        .padding(.horizontal, Layout.detailInset)
    }

    private func nodeDetailRow(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.textSecondary)
                .frame(width: NodeTableLayout.node, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.head)
                .help(row.name)

            Text(compactNodeState(row.state))
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(nodeStateTint(row))
                .frame(width: NodeTableLayout.state, alignment: .center)
                .lineLimit(1)

            Text(row.cpuText)
                .font(OrbitTheme.mono(10))
                .foregroundStyle(OrbitTheme.textSecondary)
                .frame(width: NodeTableLayout.cpu, alignment: .center)
                .lineLimit(1)

            Text(memoryUsageGBText(row))
                .font(OrbitTheme.mono(10))
                .foregroundStyle(OrbitTheme.textSecondary)
                .frame(width: NodeTableLayout.ram, alignment: .center)
                .lineLimit(1)

            Text(gpuCountText(row))
                .font(OrbitTheme.mono(10))
                .foregroundStyle(row.gpuText == nil ? OrbitTheme.textTimestamp : OrbitTheme.array.opacity(0.9))
                .frame(width: NodeTableLayout.gpu, alignment: .center)
                .lineLimit(1)

            Text(primaryPartitionLabel(row) ?? "—")
                .font(OrbitTheme.mono(10))
                .foregroundStyle(OrbitTheme.textTimestamp)
                .frame(width: NodeTableLayout.part, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Layout.detailInset)
        .padding(.vertical, 1)
    }

}
