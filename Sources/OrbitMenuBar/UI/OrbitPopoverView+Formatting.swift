import SwiftUI
import OrbitCore

extension OrbitPopoverView {
    func metricPill(value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.textSecondary)
            Text(label)
                .font(OrbitTheme.mono(9, weight: .semibold))
                .foregroundStyle(OrbitTheme.accent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(OrbitTheme.mutedFill)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .lineLimit(1)
    }

    func neutralPill(_ text: String) -> some View {
        Text(text)
            .font(OrbitTheme.mono(10, weight: .semibold))
            .foregroundStyle(OrbitTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(OrbitTheme.mutedFill)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .lineLimit(1)
    }

    func subtleMetricPill(value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.textSecondary)
            Text(label)
                .font(OrbitTheme.mono(9, weight: .semibold))
                .foregroundStyle(OrbitTheme.textTimestamp)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(OrbitTheme.mutedFill)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .lineLimit(1)
    }

    func jobIDPill(_ jobID: String) -> some View {
        HStack(spacing: 4) {
            Text("ID")
                .font(OrbitTheme.mono(9, weight: .semibold))
                .foregroundStyle(OrbitTheme.textLabel)
            Text(jobID)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(OrbitTheme.mutedFill)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    func runningMemoryValue(_ job: JobSnapshot) -> String? {
        guard let mem = job.memoryRequestedMB, mem > 0 else { return nil }
        return mem >= 1024 ? String(format: "%.0fGB", Double(mem) / 1024.0) : "\(mem)MB"
    }

    func runningNodeValue(_ job: JobSnapshot) -> String? {
        guard let node = job.nodeList?.trimmingCharacters(in: .whitespacesAndNewlines), !node.isEmpty else { return nil }
        return compactNodeLabel(node)
    }

    func remainingTimeLabel(_ job: JobSnapshot) -> String? {
        guard let limit = job.timeLimit, limit > 0 else { return nil }
        let remaining = max(0, limit - viewModel.effectiveTimeUsed(job))
        return formatRemainingDuration(remaining)
    }

    func compactNodeState(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let parts = trimmed.split(separator: "/").prefix(2)
        let compact = parts.joined(separator: "/")
        return compact.count > 13 ? String(compact.prefix(12)) + "…" : compact
    }

    func memoryUsageGBText(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> String {
        guard let totalMB = row.node.memoryMB, totalMB > 0 else { return "—" }
        let usedMB: Int?
        if let allocatedMB = row.node.memoryAllocatedMB, allocatedMB >= 0 {
            usedMB = min(allocatedMB, totalMB)
        } else if let freeMB = row.node.memoryFreeMB, freeMB >= 0 {
            usedMB = max(0, totalMB - min(freeMB, totalMB))
        } else {
            usedMB = nil
        }
        guard let usedMB else { return "—" }
        return "\(formatGBValue(usedMB))/\(formatGBValue(totalMB))"
    }

    func formatGBValue(_ memoryMB: Int) -> String {
        let gb = Double(max(0, memoryMB)) / 1024.0
        return gb >= 10 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

    func gpuCountText(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> String {
        guard let gpu = row.gpuText, !gpu.isEmpty else { return "—" }
        return gpu
    }

    func primaryPartitionLabel(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> String? {
        let partitions = row.node.partitions.filter { !$0.isEmpty }
        guard let first = partitions.first else { return nil }
        let short = first.count > 12 ? String(first.prefix(11)) + "…" : first
        return partitions.count > 1 ? "\(short)+\(partitions.count - 1)" : short
    }

    func nodeStateTint(_ row: OrbitMenuBarViewModel.NodeLoadRow) -> Color {
        switch row.severity {
        case .critical: return OrbitTheme.danger
        case .warning: return OrbitTheme.warning
        case .healthy: return OrbitTheme.success
        case .unknown: return OrbitTheme.textTimestamp
        }
    }

    func topLongestRunningTasks(_ group: OrbitMenuBarViewModel.ArrayRunningGroup, limit: Int) -> [JobSnapshot] {
        group.runningChildren
            .sorted { lhs, rhs in
                let left = viewModel.effectiveTimeUsed(lhs)
                let right = viewModel.effectiveTimeUsed(rhs)
                if abs(left - right) > 0.001 { return left > right }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func arrayStatColumn(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(OrbitTheme.mono(14, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(OrbitTheme.mono(8, weight: .semibold))
                .foregroundStyle(OrbitTheme.textTimestamp)
        }
    }

    var arrayTaskTableHeaderCompact: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("TASK")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("JOB")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("TIME")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("NODE")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(OrbitTheme.mono(9, weight: .semibold))
            .foregroundStyle(OrbitTheme.textTimestamp)

            Rectangle()
                .fill(OrbitTheme.divider)
                .frame(height: 1)
        }
    }

    func arrayTaskRowCompact(
        group: OrbitMenuBarViewModel.ArrayRunningGroup,
        job: JobSnapshot,
        fallbackIndex: Int
    ) -> some View {
        let task = arrayTaskNumberLabel(job, group: group, fallbackIndex: fallbackIndex)
        return HStack(spacing: 0) {
            Text(task)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            Button {
                viewModel.selectJob(job)
            } label: {
                Text(job.id)
                    .font(OrbitTheme.mono(10))
                    .foregroundStyle(OrbitTheme.accent)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatDuration(viewModel.effectiveTimeUsed(job)))
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(OrbitTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)

            Text(compactNodeLabel(job.nodeList))
                .font(OrbitTheme.mono(10))
                .foregroundStyle(OrbitTheme.textTimestamp)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    func arrayTaskNumberLabel(_ job: JobSnapshot, group: OrbitMenuBarViewModel.ArrayRunningGroup, fallbackIndex: Int) -> String {
        let token = resolvedArrayTaskToken(job, parentJobID: group.parentJobID) ?? String(fallbackIndex)
        return "#\(token)"
    }

    func resolvedArrayTaskToken(_ job: JobSnapshot, parentJobID: String) -> String? {
        if let exact = job.arrayTaskID { return String(exact) }
        return OrbitArrayTaskIDResolver.token(fromJobID: job.id, parentJobID: parentJobID)
    }

    func compactNodeLabel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let first = raw.split(separator: ",").first.map(String.init) ?? raw
        return first.count > 16 ? String(first.prefix(15)) + "…" : first
    }

    func arrayRuntimeSummary(_ group: OrbitMenuBarViewModel.ArrayRunningGroup) -> String? {
        let durations = group.runningChildren.map { viewModel.effectiveTimeUsed($0) }.filter { $0 > 0 }
        guard let min = durations.min(), let max = durations.max() else { return nil }
        return durations.count == 1
            ? "running for \(formatDuration(min))"
            : "running for \(formatDuration(min)) – \(formatDuration(max))"
    }

    func arrayStatusBadge(_ group: OrbitMenuBarViewModel.ArrayRunningGroup) -> some View {
        let hasWarning = group.runningChildren.contains { viewModel.isWarning($0) }
        let label = hasWarning ? "WARN" : "ARRAY"
        let color: Color = hasWarning ? OrbitTheme.warning : OrbitTheme.array
        return Text(label)
            .font(OrbitTheme.mono(10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    func statusBadge(_ job: JobSnapshot) -> some View {
        let label = viewModel.isWarning(job) ? "WARN" : "RUN"
        let color: Color = {
            if viewModel.isWarning(job) { return OrbitTheme.warning }
            if job.isArray { return OrbitTheme.array }
            return OrbitTheme.success
        }()
        return Text(label)
            .font(OrbitTheme.mono(10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    func progressTint(_ job: JobSnapshot, progress: Double) -> Color {
        if job.isArray { return OrbitTheme.array }
        if progress >= 0.9 { return OrbitTheme.accent.opacity(0.95) }
        if progress >= 0.75 { return OrbitTheme.accent.opacity(0.90) }
        return OrbitTheme.accent.opacity(0.78)
    }

    func loadTint(_ percent: Double) -> Color {
        if percent > 85 { return OrbitTheme.danger }
        if percent >= 60 { return OrbitTheme.warning }
        return OrbitTheme.success
    }

    func runningTimeLabel(_ job: JobSnapshot) -> String {
        let used = formatCompactDuration(viewModel.effectiveTimeUsed(job))

        guard let limit = job.timeLimit, limit > 0 else {
            return used
        }

        return "\(used)/\(formatCompactDuration(limit))"
    }

    func pendingReason(_ job: JobSnapshot) -> String {
        if let estimated = job.estimatedStartTime {
            return "STARTS ~\(Formatters.hourMinute.string(from: estimated))"
        }
        let raw = (job.pendingReason ?? "PENDING").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("resource") { return "RESOURCES" }
        if lower.contains("priority") { return "PRIORITY" }
        if lower.contains("depend") { return "DEPENDENCY" }
        if lower.contains("time") { return "TIME" }
        return String(raw.uppercased().prefix(14))
    }

    func jobDisplayName(_ job: JobSnapshot) -> String {
        job.isArray ? "\(job.name) [ ]" : job.name
    }

    func formatCompactDuration(_ value: TimeInterval) -> String {
        let total = Int(max(0, value))
        let days = total / 86_400
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 48 { return "\(days)d" }
        if hours >= 1 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    func formatRemainingDuration(_ value: TimeInterval) -> String {
        let total = Int(max(0, value))
        let days = total / 86_400
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 48 { return "\(days)d" }
        if hours > 1 { return "\(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    func formatDuration(_ value: TimeInterval) -> String {
        let total = Int(max(0, value))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
