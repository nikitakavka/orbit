import Foundation

extension OrbitService {
    public func watch(
        identifier: String,
        iterations: Int? = nil,
        onTick: ((LivePollResult, Int) -> Void)? = nil
    ) async throws {
        let profile = try database.loadProfile(identifier)
        try await watchLoop(profile: profile, iterations: iterations) { tick in
            onTick?(tick.result, tick.tick)
        }
    }

    public func watchAll(
        iterations: Int? = nil,
        onTick: ((ProfileWatchTick) -> Void)? = nil
    ) async throws {
        let profiles = try database.listProfiles().filter { $0.isActive }
        guard !profiles.isEmpty else {
            throw OrbitServiceError.noActiveProfiles
        }

        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask {
                    do {
                        try await self.watchLoop(profile: profile, iterations: iterations, onTick: onTick)
                    } catch {
                        // Keep remaining profiles running even if one profile has
                        // invalid config or transient connection issues.
                        self.reportInternalError("watch loop failed for profile \(profile.displayName)", error: error)
                    }
                }
            }
            await group.waitForAll()
        }
    }

    public func startLifecycleMonitoring() {
        lifecycleMonitor.start()
    }

    public func stopLifecycleMonitoring() {
        lifecycleMonitor.stop()
    }

    public func shutdown() async {
        lifecycleMonitor.stop()
        await pool.teardownAll()
    }

    private func watchLoop(
        profile: ClusterProfile,
        iterations: Int?,
        onTick: ((ProfileWatchTick) -> Void)?
    ) async throws {
        try validateProfileSupportsJSON(profile)

        var currentProfile = profile
        var connection = await pool.connection(for: currentProfile)
        var engine = try PollEngine(
            profile: currentProfile,
            connection: connection,
            database: database,
            notificationEngine: notificationEngine
        )

        var extendedTask: Task<Void, Never>?

        var count = 0

        while !Task.isCancelled {
            let refreshed = try database.loadProfile(currentProfile.id.uuidString)
            guard refreshed.isActive else { break }
            try validateProfileSupportsJSON(refreshed)

            if refreshed != currentProfile {
                currentProfile = refreshed
                connection = await pool.connection(for: currentProfile)
                engine = try PollEngine(
                    profile: currentProfile,
                    connection: connection,
                    database: database,
                    notificationEngine: notificationEngine
                )

                extendedTask?.cancel()
                if let extendedTask {
                    _ = await extendedTask.value
                }
                extendedTask = nil
            }

            let live = await engine.runLivePoll()
            count += 1
            onTick?(ProfileWatchTick(profile: currentProfile, result: live, tick: count))

            if extendedTask == nil {
                extendedTask = makeExtendedPollTask(
                    engine: engine,
                    intervalSeconds: currentProfile.extendedPollIntervalSeconds
                )
            }

            if let iterations, count >= iterations {
                break
            }

            let liveIntervalNanos = UInt64(max(1, currentProfile.pollIntervalSeconds)) * 1_000_000_000
            do {
                try await Task.sleep(nanoseconds: liveIntervalNanos)
            } catch {
                break
            }
        }

        extendedTask?.cancel()
        if let extendedTask {
            _ = await extendedTask.value
        }
    }

    private func makeExtendedPollTask(engine: PollEngine, intervalSeconds: Int) -> Task<Void, Never> {
        let intervalNanos = UInt64(max(1, intervalSeconds)) * 1_000_000_000

        return Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }

                if Task.isCancelled { break }
                await engine.runExtendedPoll()
            }
        }
    }
}
