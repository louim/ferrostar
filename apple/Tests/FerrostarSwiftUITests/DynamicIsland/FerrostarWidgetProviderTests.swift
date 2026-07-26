import ActivityKit
import FerrostarCoreFFI
import XCTest
@testable import FerrostarSwiftUI

@available(iOS 16.2, *)
private final class FakeLiveActivitySession: LiveActivitySession, @unchecked Sendable {
    private let lock = NSLock()
    private var _updateCount = 0
    private var _endCount = 0

    var updateCount: Int {
        lock.withLock { _updateCount }
    }

    var endCount: Int {
        lock.withLock { _endCount }
    }

    func update(_: ActivityContent<TripActivityAttributes.ContentState>) async {
        lock.withLock { _updateCount += 1 }
    }

    func end(dismissalPolicy _: ActivityUIDismissalPolicy) async {
        lock.withLock { _endCount += 1 }
    }
}

@available(iOS 16.2, *)
private final class FakeRequester: LiveActivityRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var _orphans: [FakeLiveActivitySession] = []
    private var _requested: [FakeLiveActivitySession] = []
    private var _requestError: Error?

    var activeSessions: [any LiveActivitySession] {
        lock.withLock { _orphans }
    }

    var orphans: [FakeLiveActivitySession] {
        lock.withLock { _orphans }
    }

    var requested: [FakeLiveActivitySession] {
        lock.withLock { _requested }
    }

    func setOrphans(_ orphans: [FakeLiveActivitySession]) {
        lock.withLock { _orphans = orphans }
    }

    func setRequestError(_ error: Error?) {
        lock.withLock { _requestError = error }
    }

    func request(
        content _: ActivityContent<TripActivityAttributes.ContentState>
    ) throws -> any LiveActivitySession {
        try lock.withLock {
            if let _requestError {
                throw _requestError
            }
            let session = FakeLiveActivitySession()
            _requested.append(session)
            return session
        }
    }
}

@available(iOS 16.2, *)
final class FerrostarWidgetProviderTests: XCTestCase {
    private struct RequestFailure: Error {}

    private func makeVisualInstruction() -> VisualInstruction {
        VisualInstruction(
            primaryContent: VisualInstructionContent(
                text: "Turn right on Something Dr.",
                maneuverType: .turn,
                maneuverModifier: .right,
                roundaboutExitDegrees: nil,
                laneInfo: nil,
                exitNumbers: []
            ),
            secondaryContent: nil,
            subContent: nil,
            triggerDistanceBeforeManeuver: 42.0
        )
    }

    private func makeProgress(distanceToNextManeuver: Double) -> TripProgress {
        TripProgress(
            distanceToNextManeuver: distanceToNextManeuver,
            distanceRemaining: distanceToNextManeuver,
            durationRemaining: distanceToNextManeuver
        )
    }

    /// Drains the provider's serial chain. Both public entry points continue on a task, so tests
    /// have to wait for the work rather than for the call to return.
    private func drain(_: FerrostarWidgetProvider) async {
        for _ in 0 ..< 5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20 * NSEC_PER_MSEC)
        }
    }

    private func update(_ provider: FerrostarWidgetProvider, distance: Double) {
        provider.update(
            visualInstruction: makeVisualInstruction(),
            spokenInstruction: nil,
            tripProgress: makeProgress(distanceToNextManeuver: distance)
        )
    }

    // MARK: - Session lifecycle

    func test_firstUpdateRequestsAnActivity() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 1000)
        await drain(provider)

        XCTAssertEqual(requester.requested.count, 1)
    }

    func test_subsequentUpdatesReuseTheSameActivity() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 1000)
        await drain(provider)
        update(provider, distance: 500)
        await drain(provider)

        XCTAssertEqual(requester.requested.count, 1, "One trip, one activity")
        XCTAssertEqual(requester.requested.first?.updateCount, 1)
    }

    func test_terminateEndsTheActivity() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 1000)
        await drain(provider)
        provider.terminate()
        await drain(provider)

        XCTAssertEqual(requester.requested.first?.endCount, 1)
    }

    /// The bug this branch exists for. `terminate()` used to end the activity without clearing it,
    /// so a provider reused for a second trip took the update path against an activity the system
    /// had already ended — which silently does nothing, leaving the user with no live activity at
    /// all for the rest of that trip.
    func test_providerReusedAfterTerminateRequestsAFreshActivity() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 1000)
        await drain(provider)
        provider.terminate()
        await drain(provider)

        // Second trip on the same provider.
        update(provider, distance: 900)
        await drain(provider)

        XCTAssertEqual(requester.requested.count, 2, "A new trip needs a new activity")
        XCTAssertEqual(requester.requested.last?.endCount, 0, "The new activity is still live")
    }

    /// `lastUpdateDistance` has to be cleared too, or the first update of the second trip is
    /// compared against a distance from the first one and can be discarded by the threshold.
    func test_firstUpdateOfASecondTripIsNeverDiscardedByTheThreshold() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 30)
        await drain(provider)
        provider.terminate()
        await drain(provider)

        // Within the 5m threshold of the previous trip's last distance.
        update(provider, distance: 28)
        await drain(provider)

        XCTAssertEqual(requester.requested.count, 2)
    }

    func test_updatesBelowTheThresholdAreDiscarded() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 1000)
        await drain(provider)
        // > 1km band updates every 100m.
        update(provider, distance: 990)
        await drain(provider)

        XCTAssertEqual(requester.requested.first?.updateCount, 0)
    }

    // MARK: - Orphans

    /// A force quit never reaches `terminate()`, so the system goes on showing that trip's activity
    /// after the process that could end it is gone.
    func test_orphanedActivitiesAreEndedBeforeTheFirstRequest() async {
        let requester = FakeRequester()
        let orphan = FakeLiveActivitySession()
        requester.setOrphans([orphan])

        let provider = FerrostarWidgetProvider(requester: requester)
        update(provider, distance: 1000)
        await drain(provider)

        XCTAssertEqual(orphan.endCount, 1)
        XCTAssertEqual(requester.requested.count, 1)
        XCTAssertEqual(requester.requested.first?.endCount, 0, "The sweep must not end our own new activity")
    }

    func test_orphansAreOnlyCheckedOnce() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 1000)
        await drain(provider)

        // An activity appearing later is ours, or another provider's; either way it is not an
        // orphan and ending it would be destructive.
        let laterActivity = FakeLiveActivitySession()
        requester.setOrphans([laterActivity])

        provider.terminate()
        await drain(provider)
        update(provider, distance: 500)
        await drain(provider)

        XCTAssertEqual(laterActivity.endCount, 0)
    }

    // MARK: - Ordering

    /// `update(...)` and `terminate()` are both fire-and-forget. Unserialised, a terminate can
    /// complete while the request is still in flight — ending nothing, because the activity does
    /// not exist yet — and the activity then appears immediately afterwards with nobody left to
    /// end it. The user is left with a live activity for a trip that is over.
    func test_terminateImmediatelyAfterUpdateStillEndsTheActivity() async {
        let requester = FakeRequester()
        let provider = FerrostarWidgetProvider(requester: requester)

        update(provider, distance: 1000)
        provider.terminate() // no drain in between: the request is still in flight
        await drain(provider)

        XCTAssertEqual(requester.requested.count, 1)
        XCTAssertEqual(requester.requested.first?.endCount, 1, "The in-flight activity must still be ended")
    }

    // MARK: - Failure

    func test_aFailedRequestDoesNotWedgeTheProvider() async {
        let requester = FakeRequester()
        requester.setRequestError(RequestFailure())

        let provider = FerrostarWidgetProvider(requester: requester)
        update(provider, distance: 1000)
        await drain(provider)

        XCTAssertEqual(requester.requested.count, 0)

        // The next update must try again rather than assume an activity exists.
        requester.setRequestError(nil)
        update(provider, distance: 500)
        await drain(provider)

        XCTAssertEqual(requester.requested.count, 1)
    }
}
