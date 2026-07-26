import ActivityKit
import CoreLocation
import FerrostarCore
import FerrostarCoreFFI
import OSLog

private let logger = Logger(subsystem: "com.stadiamaps.ferrostar", category: "FerrostarWidgetProvider")

@available(iOS 16.2, *)
public class FerrostarWidgetProvider: WidgetProviding {
    private let requester: any LiveActivityRequesting

    /// Guards the mutable state below.
    ///
    /// `update(...)` is called from the navigation state machine and `terminate()` from wherever
    /// navigation is stopped, without coordination between them, and each continues on its own
    /// task afterwards.
    private let lock = NSLock()
    private var session: (any LiveActivitySession)?
    private var lastUpdateDistance: CLLocationDistance?
    private var hasCheckedForOrphans = false
    /// Tail of the serial chain; see ``enqueue(_:)``.
    private var tail: Task<Void, Never>?

    public convenience init() {
        self.init(requester: ActivityKitRequester())
    }

    init(requester: any LiveActivityRequesting) {
        self.requester = requester
    }

    deinit {
        tail?.cancel()
    }

    public func update(
        visualInstruction: VisualInstruction,
        spokenInstruction: SpokenInstruction?,
        tripProgress: TripProgress
    ) {
        let currentDistance = tripProgress.distanceToNextManeuver

        // Tested and recorded together: two updates arriving at once would otherwise both compare
        // against the same stale distance and both decide to proceed.
        let shouldUpdate = lock.withLock {
            guard shouldUpdateLocked(currentDistance: currentDistance) else { return false }
            lastUpdateDistance = currentDistance
            return true
        }

        guard shouldUpdate else { return }

        if let spokenInstruction {
            logger.debug("Alert w/ \(spokenInstruction.text)")
        }

        enqueue { [weak self] in
            await self?.requestOrUpdate(visualInstruction: visualInstruction, tripProgress: tripProgress)
        }
    }

    public func terminate() {
        enqueue { [weak self] in
            await self?.endSession()
        }
    }

    /// Runs `work` after everything already queued.
    ///
    /// `update(...)` and `terminate()` both continue asynchronously, and left unordered a
    /// `terminate()` can complete while a request is still in flight — ending nothing, because the
    /// activity does not exist yet, and then having one appear immediately afterwards that nobody
    /// will ever end. Serialising them means terminate always sees whatever the update produced.
    ///
    /// The lock is held only for the tail swap, never while a work item runs, so enqueuing from
    /// inside a work item would be safe.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                await work()
            }
        }
    }

    private func requestOrUpdate(visualInstruction: VisualInstruction, tripProgress: TripProgress) async {
        let content = ActivityContent(
            state: TripActivityAttributes.ContentState(
                instruction: visualInstruction,
                distanceToNextManeuver: tripProgress.distanceToNextManeuver
            ),
            staleDate: nil
        )

        if let session = lock.withLock({ self.session }) {
            await session.update(content)
            return
        }

        await endOrphanedSessions()

        do {
            let session = try requester.request(content: content)
            lock.withLock { self.session = session }
        } catch {
            logger.error("Failed to request Dynamic Island activity: \(error.localizedDescription)")
        }
    }

    /// Ends activities left behind by a previous run of the app.
    ///
    /// A force quit never reaches ``terminate()``, so the system goes on showing that trip's
    /// activity while the process that could have ended it is gone. Nothing else will ever clean
    /// these up, and requesting a second activity on top would leave the user looking at two.
    ///
    /// Checked once per provider, immediately before the first request, so it cannot catch the
    /// activity we are about to create.
    private func endOrphanedSessions() async {
        let shouldCheck = lock.withLock {
            guard !hasCheckedForOrphans else { return false }
            hasCheckedForOrphans = true
            return true
        }

        guard shouldCheck else { return }

        for orphan in requester.activeSessions {
            logger.info("Ending an orphaned trip activity left over from a previous session")
            await orphan.end(dismissalPolicy: .immediate)
        }
    }

    private func endSession() async {
        // Cleared as the session is taken, so a provider reused for a second trip starts clean.
        // Leaving the finished activity in place is not inert: the next trip would take the update
        // path against an activity the system has already ended, which silently does nothing, and
        // no live activity would ever appear again.
        let session = lock.withLock { () -> (any LiveActivitySession)? in
            let session = self.session
            self.session = nil
            lastUpdateDistance = nil
            return session
        }

        await session?.end(dismissalPolicy: .immediate)
    }

    private func shouldUpdateLocked(currentDistance: CLLocationDistance) -> Bool {
        guard let lastDistance = lastUpdateDistance else {
            // First update
            return true
        }

        let distanceChange = abs(lastDistance - currentDistance)
        let threshold = updateThreshold(for: currentDistance)

        return distanceChange >= threshold
    }

    private func updateThreshold(for distance: CLLocationDistance) -> CLLocationDistance {
        // TODO: This could be way nicer, but it get's the job done as a starting point.
        // Progressive scaling: closer to maneuver = more frequent updates
        switch distance {
        case 0 ..< 50: // < 50m: update every 5m
            5
        case 50 ..< 100: // 50-100m: update every 10m
            10
        case 100 ..< 200: // 100-200m: update every 15m
            15
        case 200 ..< 500: // 200-500m: update every 25m
            25
        case 500 ..< 1000: // 500m-1km: update every 50m
            50
        default: // > 1km: update every 100m
            100
        }
    }
}
