import SwiftUI
import Combine

struct OrbitIdleStateView: View {
    struct LoadPhraseRange {
        let lowerBound: Double
        let upperBound: Double?
        let options: [String]

        func contains(_ value: Double) -> Bool {
            if value < lowerBound { return false }
            if let upperBound {
                return value < upperBound
            }
            return true
        }
    }

    struct DayBar: Identifiable {
        let id: String
        let shortLabel: String
        let cpuHours: Double?
        let isToday: Bool
    }

    struct Data {
        let statusTitle: String
        let statusTrailingText: String?
        let statusDotColor: Color
        let loadPercent: Double?
        let loadPhraseRanges: [LoadPhraseRange]
        let loadPhraseFallback: String
        let weekRangeText: String
        let weeklyBars: [DayBar]
        let totalJobsThisWeek: Int?
        let totalCPUHoursThisWeek: Double?
        let estimatedCostThisWeek: Double?
        let cpuHourRate: Double
    }

    let data: Data

    @State private var selectedLoadPhrase: String = ""
    @State private var renderedLoadPhrase: String = ""
    @State private var typingTask: Task<Void, Never>?

    init(data: Data) {
        self.data = data

        if ProcessInfo.processInfo.environment["ORBIT_UI_CAPTURE_SCALE"] != nil {
            let phrase = Self.randomLoadPhrase(
                loadPercent: data.loadPercent,
                ranges: data.loadPhraseRanges,
                fallback: data.loadPhraseFallback
            )
            _selectedLoadPhrase = State(initialValue: phrase)
            _renderedLoadPhrase = State(initialValue: phrase)
        }
    }

    private let phraseRotationTimer = Timer.publish(every: 5 * 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(data.statusDotColor)
                    .frame(width: 6, height: 6)

                Text(data.statusTitle)
                    .font(OrbitTheme.mono(11, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textPrimary)

                Spacer(minLength: 8)

                if let trailing = data.statusTrailingText, !trailing.isEmpty {
                    Text(trailing)
                        .font(OrbitTheme.mono(11))
                        .foregroundStyle(OrbitTheme.textSecondary)
                }
            }

            Text(renderedLoadPhrase)
                .font(OrbitTheme.mono(11))
                .foregroundStyle(OrbitTheme.textSecondary)

            thisWeekSection
        }
        .padding(.vertical, 10)
        .onAppear {
            showNextPhrase(preferDifferent: false, animate: selectedLoadPhrase.isEmpty)
        }
        .onChange(of: data.loadPercent) { _ in
            showNextPhrase(preferDifferent: true, animate: true)
        }
        .onReceive(phraseRotationTimer) { _ in
            showNextPhrase(preferDifferent: true, animate: true)
        }
        .onDisappear {
            typingTask?.cancel()
            typingTask = nil
        }
    }

    private var thisWeekSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("THIS WEEK")
                    .font(OrbitTheme.mono(12, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textLabel)
                    .tracking(1.0)

                Spacer()

                Text(data.weekRangeText)
                    .font(OrbitTheme.mono(11, weight: .semibold))
                    .foregroundStyle(OrbitTheme.textSecondary)
            }

            weeklyBars

            HStack(spacing: 8) {
                statPill(title: "JOBS", value: jobsValueText, subtitle: "this week", accent: true)
                statPill(title: "CPU·H", value: cpuHoursValueText, subtitle: "core hours")
                statPill(title: "EST. COST", value: estimatedCostText, subtitle: rateSubtitle, accent: true)
            }
        }
    }

    private var weeklyBars: some View {
        let values = data.weeklyBars.compactMap { $0.cpuHours }
        let maxValue = max(values.max() ?? 0, 1)

        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(data.weeklyBars) { bar in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barColor(bar))
                        .frame(height: barHeight(bar, maxValue: maxValue))

                    Text(bar.shortLabel)
                        .font(OrbitTheme.mono(9, weight: bar.isToday ? .semibold : .regular))
                        .foregroundStyle(bar.isToday ? OrbitTheme.accent : OrbitTheme.textTimestamp)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 54, alignment: .bottom)
    }

    @ViewBuilder
    private func statPill(title: String, value: String, subtitle: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(OrbitTheme.mono(11, weight: .semibold))
                .foregroundStyle(OrbitTheme.textLabel)

            Text(value)
                .font(OrbitTheme.mono(12, weight: .semibold))
                .foregroundStyle(accent ? OrbitTheme.accent : OrbitTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(subtitle)
                .font(OrbitTheme.mono(10))
                .foregroundStyle(OrbitTheme.textTimestamp)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(OrbitTheme.mutedFill)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var jobsValueText: String {
        guard let totalJobs = data.totalJobsThisWeek else { return "—" }
        return Self.formatCompactMetric(Double(totalJobs), isWholePreferred: true)
    }

    private var cpuHoursValueText: String {
        guard let total = data.totalCPUHoursThisWeek else { return "—" }
        return Self.formatCompactMetric(total, isWholePreferred: false)
    }

    private var estimatedCostText: String {
        guard let value = data.estimatedCostThisWeek else { return "—" }
        return Self.formatCompactCurrency(value)
    }

    private var rateSubtitle: String {
        String(format: "@ $%.2f/CPU·h", data.cpuHourRate)
    }

    private func barHeight(_ bar: DayBar, maxValue: Double) -> CGFloat {
        guard let value = bar.cpuHours else { return 2 }
        if value <= 0 { return 2 }
        let normalized = min(1.0, max(0.0, value / maxValue))
        return max(2, CGFloat(normalized) * 26)
    }

    private func barColor(_ bar: DayBar) -> Color {
        guard bar.cpuHours != nil else {
            return OrbitTheme.textTimestamp.opacity(0.4)
        }

        if bar.isToday {
            return OrbitTheme.accent
        }

        return OrbitTheme.accent.opacity(0.35)
    }

    private func showNextPhrase(preferDifferent: Bool, animate: Bool) {
        let next = Self.randomLoadPhrase(
            loadPercent: data.loadPercent,
            ranges: data.loadPhraseRanges,
            fallback: data.loadPhraseFallback,
            excluding: preferDifferent ? selectedLoadPhrase : nil
        )

        let shouldAnimate = animate && (next != selectedLoadPhrase || renderedLoadPhrase.isEmpty)
        selectedLoadPhrase = next

        if shouldAnimate {
            typePhrase(next)
        } else {
            renderedLoadPhrase = next
        }
    }

    private func typePhrase(_ phrase: String) {
        typingTask?.cancel()
        renderedLoadPhrase = ""

        typingTask = Task {
            for character in phrase {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 75_000_000)
                await MainActor.run {
                    renderedLoadPhrase.append(character)
                }
            }
        }
    }

    static func randomLoadPhrase(
        loadPercent: Double?,
        ranges: [LoadPhraseRange],
        fallback: String,
        excluding currentPhrase: String? = nil
    ) -> String {
        let options = phraseOptions(loadPercent: loadPercent, ranges: ranges, fallback: fallback)

        guard let currentPhrase,
              options.count > 1 else {
            return options.randomElement() ?? fallback
        }

        let filtered = options.filter { $0 != currentPhrase }
        return filtered.randomElement() ?? options.randomElement() ?? fallback
    }

    private static func phraseOptions(loadPercent: Double?, ranges: [LoadPhraseRange], fallback: String) -> [String] {
        guard let loadPercent else { return [fallback] }
        guard let range = ranges.first(where: { $0.contains(loadPercent) }) else { return [fallback] }

        let normalized = range.options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return normalized.isEmpty ? [fallback] : normalized
    }

    private static func formatCompactCurrency(_ raw: Double) -> String {
        let value = max(0, raw)

        if value >= 1_000_000_000 {
            return String(format: "$%.2f B", value / 1_000_000_000)
        }

        if value >= 1_000_000 {
            return String(format: "$%.2f M", value / 1_000_000)
        }

        if value >= 100_000 {
            return String(format: "$%.1f K", value / 1_000)
        }

        return String(format: "$%.2f", value)
    }

    private static func formatCompactMetric(_ raw: Double, isWholePreferred: Bool) -> String {
        let value = max(0, raw)

        if value >= 1_000_000_000 {
            return String(format: "%.2f B", value / 1_000_000_000)
        }

        if value >= 1_000_000 {
            return String(format: "%.2f M", value / 1_000_000)
        }

        if value >= 100_000 {
            return String(format: "%.1f K", value / 1_000)
        }

        let fractionDigits: Int
        if isWholePreferred {
            fractionDigits = 0
        } else {
            fractionDigits = value >= 100 ? 0 : 1
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits

        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
