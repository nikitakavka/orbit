import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

public final class ConnectionLifecycleMonitor {
    private let pool: SSHConnectionPool
    private let queue = DispatchQueue(label: "orbit.connection.lifecycle")

    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private let lock = NSLock()

    public init(pool: SSHConnectionPool) {
        self.pool = pool
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !started else { return }
        started = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied, let self else { return }
            Task { await self.pool.reconnectAllIfNeeded() }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor

        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.pool.reconnectAllIfNeeded() }
        }
        #endif
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard started else { return }
        started = false

        pathMonitor?.cancel()
        pathMonitor = nil

        #if canImport(AppKit)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        #endif
        wakeObserver = nil
    }

    deinit {
        stop()
    }
}
