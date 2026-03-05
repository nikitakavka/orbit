import Foundation

extension OrbitService {
    public func weeklyUsage(profileId: UUID, referenceDate: Date = Date()) throws -> WeeklyUsageSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2 // Monday
        calendar.minimumDaysInFirstWeek = 4

        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
            let start = calendar.startOfDay(for: referenceDate)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            return WeeklyUsageSummary(
                profileId: profileId,
                weekStart: start,
                weekEnd: end,
                totalJobs: 0,
                totalCPUHours: 0,
                dailyCPUHours: []
            )
        }

        let weekStart = weekInterval.start
        let weekEnd = weekInterval.end
        let periodEnd = min(referenceDate, weekEnd)

        let totalJobs = try database.observedLiveJobCount(profileId: profileId, from: weekStart, to: periodEnd)
        let observedSeries = try database.observedCoreUsageSeries(
            profileId: profileId,
            from: weekStart,
            to: periodEnd,
            includePreviousSample: true
        )
        let coreHistory = observedSeries.isEmpty
            ? try database.cpuCoreHistory(profileId: profileId, from: weekStart, to: periodEnd, includePreviousSample: true)
            : observedSeries

        let pollInterval: Int
        do {
            pollInterval = try database.loadProfile(profileId.uuidString).pollIntervalSeconds
        } catch {
            reportInternalError("loading profile poll interval for weekly usage", error: error)
            pollInterval = 30
        }
        let maxInterpolatedGap = TimeInterval(max(10 * 60, pollInterval * 4))

        var cpuHoursByDay: [Date: Double] = [:]

        if !coreHistory.isEmpty {
            for index in 0..<coreHistory.count {
                let sample = coreHistory[index]
                let start = max(sample.timestamp, weekStart)

                var end: Date
                if index + 1 < coreHistory.count {
                    end = min(coreHistory[index + 1].timestamp, periodEnd)
                } else {
                    end = periodEnd
                }

                guard end > start else { continue }

                if end.timeIntervalSince(start) > maxInterpolatedGap {
                    end = start.addingTimeInterval(maxInterpolatedGap)
                }

                guard end > start else { continue }
                distributeCPUHours(
                    from: start,
                    to: end,
                    cores: sample.totalCoresInUse,
                    calendar: calendar,
                    buckets: &cpuHoursByDay
                )
            }
        }

        var daily: [WeeklyUsageSummary.DayUsage] = []
        daily.reserveCapacity(7)

        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let key = calendar.startOfDay(for: day)
            daily.append(WeeklyUsageSummary.DayUsage(date: key, cpuHours: cpuHoursByDay[key] ?? 0))
        }

        let totalCPUHours = daily.reduce(0) { $0 + $1.cpuHours }

        return WeeklyUsageSummary(
            profileId: profileId,
            weekStart: weekStart,
            weekEnd: weekEnd,
            totalJobs: totalJobs,
            totalCPUHours: totalCPUHours,
            dailyCPUHours: daily
        )
    }

    func distributeCPUHours(
        from start: Date,
        to end: Date,
        cores: Int,
        calendar: Calendar,
        buckets: inout [Date: Double]
    ) {
        guard end > start, cores > 0 else { return }

        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(end, nextDay)
            let durationHours = segmentEnd.timeIntervalSince(cursor) / 3600.0
            buckets[dayStart, default: 0] += max(0, durationHours * Double(cores))
            cursor = segmentEnd
        }
    }
}
