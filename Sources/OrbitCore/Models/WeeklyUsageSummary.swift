import Foundation

public struct WeeklyUsageSummary: Equatable {
    public struct DayUsage: Equatable {
        public let date: Date
        public let cpuHours: Double

        public init(date: Date, cpuHours: Double) {
            self.date = date
            self.cpuHours = max(0, cpuHours)
        }
    }

    public let profileId: UUID
    public let weekStart: Date
    public let weekEnd: Date
    public let totalJobs: Int
    public let totalCPUHours: Double
    public let dailyCPUHours: [DayUsage]

    public init(
        profileId: UUID,
        weekStart: Date,
        weekEnd: Date,
        totalJobs: Int,
        totalCPUHours: Double,
        dailyCPUHours: [DayUsage]
    ) {
        self.profileId = profileId
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.totalJobs = max(0, totalJobs)
        self.totalCPUHours = max(0, totalCPUHours)
        self.dailyCPUHours = dailyCPUHours
    }
}
