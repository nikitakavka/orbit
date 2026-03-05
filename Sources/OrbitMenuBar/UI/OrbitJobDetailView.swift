import SwiftUI
import OrbitCore

struct OrbitJobDetailView: View {
    let clusterName: String
    let job: JobSnapshot
    let history: JobHistorySnapshot?
    let sacctAvailable: Bool
    let onClose: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        ZStack {
            OrbitTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                divider
                jobMetaSection
                divider
                efficiencySection
                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Button("Close") {
                        onClose()
                    }
                    .buttonStyle(.plain)
                    .font(OrbitTheme.mono(11, weight: .semibold))
                    .foregroundStyle(OrbitTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrbitTheme.accent.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.top, 12)
            }
            .padding(14)
        }
        .frame(minWidth: 430, minHeight: 320)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(job.name)
                .font(OrbitTheme.mono(12, weight: .semibold))
                .foregroundStyle(OrbitTheme.textPrimary)
                .lineLimit(1)

            Text("·")
                .font(OrbitTheme.mono(12))
                .foregroundStyle(OrbitTheme.textLabel)

            Text(clusterName)
                .font(OrbitTheme.mono(11))
                .foregroundStyle(OrbitTheme.textSecondary)

            Spacer()

            Text(job.state.rawValue)
                .font(OrbitTheme.mono(10, weight: .semibold))
                .foregroundStyle(stateColor(job.state))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(stateColor(job.state).opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(.vertical, 10)
    }

    private var jobMetaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRow("Job ID", value: job.id)
            detailRow("Elapsed", value: elapsedLabel)
            detailRow("Partition", value: job.partition)
            detailRow("Node", value: nodeLabel)
            detailRow("CPUs", value: "\(job.cpus)")
            detailRow("Memory", value: memoryLabel)
            detailRow("GPU", value: gpuLabel)
            detailRow("Started", value: job.startTime.map(formatTime) ?? "—")

            if job.state == .pending, let reason = job.pendingReason {
                detailRow("Reason", value: reason)
            }

            if let wd = job.workingDirectory, !wd.isEmpty {
                detailRow("Work dir", value: wd, multiline: true)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var efficiencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EFFICIENCY")
                .font(OrbitTheme.mono(11, weight: .semibold))
                .foregroundStyle(OrbitTheme.textLabel)
                .tracking(1.0)

            if !sacctAvailable {
                Text("sacct history is disabled on this cluster.")
                    .font(OrbitTheme.mono(11))
                    .foregroundStyle(OrbitTheme.textTimestamp)
            } else if let history {
                detailRow("CPU efficiency", value: efficiencyLabel(history.cpuEfficiency), warning: cpuWarning(history.cpuEfficiency))
                detailRow("Memory efficiency", value: efficiencyLabel(history.memoryEfficiency), warning: memoryWarning(history.memoryEfficiency))

                if let code = history.exitCode, !code.isEmpty, !isRunning(job.state) {
                    detailRow("Exit code", value: code)
                } else {
                    detailRow("Exit code", value: "—")
                }
            } else {
                Text("No sacct metrics yet for this job.")
                    .font(OrbitTheme.mono(11))
                    .foregroundStyle(OrbitTheme.textTimestamp)
            }
        }
        .padding(.vertical, 12)
    }

    private func detailRow(_ label: String, value: String, warning: Bool = false, multiline: Bool = false) -> some View {
        HStack(alignment: multiline ? .top : .center, spacing: 8) {
            Text(label)
                .font(OrbitTheme.mono(11))
                .foregroundStyle(OrbitTheme.textLabel)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(OrbitTheme.mono(11))
                .foregroundStyle(OrbitTheme.textSecondary)
                .lineLimit(multiline ? 3 : 1)
                .textSelection(.enabled)

            if warning {
                Text("⚠")
                    .font(OrbitTheme.mono(11, weight: .semibold))
                    .foregroundStyle(OrbitTheme.warning)
            }

            Spacer(minLength: 0)
        }
    }

    private var elapsedLabel: String {
        let used = formatDuration(job.timeUsed)
        if let limit = job.timeLimit {
            return "\(used) / \(formatDuration(limit))"
        }
        return used
    }

    private var nodeLabel: String {
        if let node = job.nodeList, !node.isEmpty {
            return node
        }
        return job.nodes > 0 ? "\(job.nodes) node(s)" : "—"
    }

    private var memoryLabel: String {
        guard let mb = job.memoryRequestedMB, mb > 0 else { return "—" }
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }

    private var gpuLabel: String {
        guard let gpu = job.gpuCount, gpu > 0 else { return "—" }
        return "\(gpu)"
    }

    private func efficiencyLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func cpuWarning(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value < 0.50
    }

    private func memoryWarning(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value < 0.30
    }

    private func stateColor(_ state: JobState) -> Color {
        switch state {
        case .running: return OrbitTheme.success
        case .pending: return OrbitTheme.warning
        case .failed, .timeout, .outOfMemory, .cancelled: return OrbitTheme.danger
        case .completed: return OrbitTheme.array
        default: return OrbitTheme.textSecondary
        }
    }

    private func isRunning(_ state: JobState) -> Bool {
        state == .running || state == .completing
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        let total = Int(max(0, value))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m"
        }

        return "\(seconds)s"
    }

    private var divider: some View {
        Rectangle()
            .fill(OrbitTheme.divider)
            .frame(height: 1)
    }
}
