import AVFoundation
import os
import XCTest
@testable import FerrostarCore

/// Records the exact calls made to `AVAudioSession`.
///
/// The call *sequence* is the contract worth pinning: the failures this module exists to prevent
/// are all ordering failures — activating without the right mode, or deactivating while somebody
/// is still audible.
private final class FakeAudioSessionHandle: AudioSessionHandle {
    enum Call: Equatable, Sendable {
        case setCategory(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)
        case setActive(Bool, AVAudioSession.SetActiveOptions)
    }

    struct ActivationRefused: Error {}

    private struct State {
        var calls: [Call] = []
        /// While `true`, `setActive(true)` throws — the real session does this when
        /// the system refuses activation, e.g. during an interruption.
        var refusesActivation = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    var refusesActivation: Bool {
        get { state.withLock { $0.refusesActivation } }
        set { state.withLock { $0.refusesActivation = newValue } }
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        state.withLock { $0.calls.append(.setCategory(category, mode, options)) }
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        let refused = state.withLock { state -> Bool in
            state.calls.append(.setActive(active, options))
            return active && state.refusesActivation
        }
        if refused {
            throw ActivationRefused()
        }
    }
}

final class AudioSessionManagerTests: XCTestCase {
    private var session: FakeAudioSessionHandle!
    private var subject: AudioSessionManager!

    override func setUp() {
        super.setUp()
        session = FakeAudioSessionHandle()
        subject = AudioSessionManager(session: session)
    }

    override func tearDown() {
        subject = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Activation

    /// Pins ferrostar#608 (ducking) and ferrostar#613 (`.voicePrompt`), and pins that category,
    /// mode and options are applied in a *single* call. Setting the category alone momentarily
    /// drops the mode to `.default`, and doing that under a live utterance cuts it mid-sentence.
    func test_firstHoldActivatesWithTheNavigationConfiguration() async {
        _ = await subject.acquireAudioFocus()

        XCTAssertEqual(session.calls, [
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
        ])
    }

    func test_customConfigurationIsApplied() async {
        let session = FakeAudioSessionHandle()
        let subject = AudioSessionManager(
            configuration: .init(category: .ambient, mode: .default, options: [.mixWithOthers]),
            session: session
        )

        _ = await subject.acquireAudioFocus()

        XCTAssertEqual(session.calls, [
            .setCategory(.ambient, .default, [.mixWithOthers]),
            .setActive(true, []),
        ])
    }

    func test_secondHoldDoesNotReactivate() async {
        _ = await subject.acquireAudioFocus()
        let callsAfterFirst = session.calls

        _ = await subject.acquireAudioFocus()

        XCTAssertEqual(session.calls, callsAfterFirst, "The session is already active")
    }

    // MARK: - Release

    func test_lastReleaseDeactivatesAndNotifiesOthers() async {
        let hold = await subject.acquireAudioFocus()

        await subject.releaseAudioFocus(hold)

        XCTAssertEqual(session.calls.last, .setActive(false, .notifyOthersOnDeactivation))
        let hasAudioFocus = await subject.hasAudioFocus
        XCTAssertFalse(hasAudioFocus)
    }

    /// The case that motivated reference counting. Spoken guidance and an arrival chime are
    /// concurrent, unrelated holders with no containment relationship — the chime fires from a
    /// step-completion callback while speech is mid-queue — so the holds do not nest and whichever
    /// finishes first must not deactivate the session.
    func test_overlappingUnrelatedHolds_firstReleaseKeepsSessionActive() async {
        let speech = await subject.acquireAudioFocus()
        let chime = await subject.acquireAudioFocus()

        // The chime started second and finishes first: not a nested scope.
        await subject.releaseAudioFocus(chime)

        XCTAssertFalse(
            session.calls.contains(.setActive(false, .notifyOthersOnDeactivation)),
            "Deactivating here would cut the utterance that is still being spoken"
        )
        var hasAudioFocus = await subject.hasAudioFocus
        XCTAssertTrue(hasAudioFocus)

        await subject.releaseAudioFocus(speech)

        XCTAssertEqual(session.calls.last, .setActive(false, .notifyOthersOnDeactivation))
        hasAudioFocus = await subject.hasAudioFocus
        XCTAssertFalse(hasAudioFocus)
    }

    func test_doubleReleaseOfTheSameHoldIsIgnored() async {
        let speech = await subject.acquireAudioFocus()
        let chime = await subject.acquireAudioFocus()

        await subject.releaseAudioFocus(chime)
        await subject.releaseAudioFocus(chime)

        let hasAudioFocus = await subject.hasAudioFocus
        XCTAssertTrue(hasAudioFocus, "A repeated release must not drop somebody else's claim")
        XCTAssertFalse(session.calls.contains(.setActive(false, .notifyOthersOnDeactivation)))

        await subject.releaseAudioFocus(speech)
        let hasAudioFocusAfter = await subject.hasAudioFocus
        XCTAssertFalse(hasAudioFocusAfter)
    }

    func test_releasingAnUnknownHoldIsIgnored() async {
        let speech = await subject.acquireAudioFocus()

        await subject.releaseAudioFocus(AudioFocusHold())

        let hasAudioFocus = await subject.hasAudioFocus
        XCTAssertTrue(hasAudioFocus)
        XCTAssertFalse(session.calls.contains(.setActive(false, .notifyOthersOnDeactivation)))

        await subject.releaseAudioFocus(speech)
        let hasAudioFocusAfter = await subject.hasAudioFocus
        XCTAssertFalse(hasAudioFocusAfter)
    }

    func test_reacquiringAfterFullReleaseReactivates() async {
        let first = await subject.acquireAudioFocus()
        await subject.releaseAudioFocus(first)

        _ = await subject.acquireAudioFocus()

        XCTAssertEqual(session.calls, [
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
            .setActive(false, .notifyOthersOnDeactivation),
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
        ])
    }

    // MARK: - Activation failure

    /// Activation can throw — most plainly while the audio server is restarting — and the hold
    /// count must not remember that as success: with "first hold activates" bookkeeping, no later
    /// acquire ever tries again and guidance plays into a dead session for the rest of the trip.
    /// A failed activation must leave the manager knowing the session is NOT active, so the next
    /// acquire retries instead of skipping.
    func test_failedActivation_isRetriedOnTheNextAcquire() async {
        session.refusesActivation = true
        let first = await subject.acquireAudioFocus()

        session.refusesActivation = false
        _ = await subject.acquireAudioFocus()

        XCTAssertEqual(session.calls, [
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
        ])

        // Both holds are real regardless of the failed first attempt.
        await subject.releaseAudioFocus(first)
        let hasAudioFocus = await subject.hasAudioFocus
        XCTAssertTrue(hasAudioFocus)
    }

    /// If activation never succeeded, there is nothing to deactivate: calling `setActive(false)`
    /// on a session somebody else controls is exactly the kind of blind write this manager
    /// exists to prevent.
    func test_releaseAfterFailedActivation_doesNotDeactivate() async {
        session.refusesActivation = true
        let hold = await subject.acquireAudioFocus()

        await subject.releaseAudioFocus(hold)

        XCTAssertFalse(session.calls.contains(.setActive(false, .notifyOthersOnDeactivation)))
    }

    // MARK: - System interruptions and media services reset

    /// A system interruption (phone call, dictation) deactivates the session underneath us
    /// without touching the holds. When it ends, guidance is still mid-trip — the session must
    /// come back, full configuration included, or every later sound plays into a dead session.
    func test_interruptionEnded_reactivatesWhileHoldsOutstanding() async {
        _ = await subject.acquireAudioFocus()
        let callsBeforeInterruption = session.calls

        await subject.handleAudioSessionInterruption(type: .began)
        XCTAssertEqual(session.calls, callsBeforeInterruption, "Nothing to do; the system already deactivated us")

        await subject.handleAudioSessionInterruption(type: .ended)

        XCTAssertEqual(session.calls, callsBeforeInterruption + [
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
        ])
    }

    func test_interruption_withNoHolds_doesNotTouchTheSession() async {
        await subject.handleAudioSessionInterruption(type: .began)
        await subject.handleAudioSessionInterruption(type: .ended)

        XCTAssertEqual(session.calls, [])
    }

    /// After the system deactivates us, the last release has nothing of ours to give back —
    /// and must not blindly write to a session another app may now be driving.
    func test_releaseAfterSystemDeactivation_doesNotDeactivate() async {
        let hold = await subject.acquireAudioFocus()
        await subject.handleAudioSessionInterruption(type: .began)

        await subject.releaseAudioFocus(hold)

        XCTAssertFalse(session.calls.contains(.setActive(false, .notifyOthersOnDeactivation)))
    }

    /// The system may refuse activation while the interrupting audio still owns the route —
    /// a hold taken in that window must not be stranded; interruption end retries for it.
    func test_activationRefusedDuringInterruption_isRecoveredOnInterruptionEnd() async {
        await subject.handleAudioSessionInterruption(type: .began)
        session.refusesActivation = true
        _ = await subject.acquireAudioFocus()

        session.refusesActivation = false
        await subject.handleAudioSessionInterruption(type: .ended)

        XCTAssertEqual(session.calls.suffix(2), [
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
        ])
    }

    /// The audio server crashing mid-trip evaporates every server-side resource. If the session
    /// is never reconfigured, later speech re-activates it implicitly with `.duckOthers` latched,
    /// ducking every other app until the process is killed. After a reset, the full configuration
    /// must be re-applied on the spot.
    func test_mediaServicesReset_reappliesConfigurationWhileHoldsOutstanding() async {
        _ = await subject.acquireAudioFocus()
        let callsBeforeReset = session.calls

        await subject.handleMediaServicesReset()

        XCTAssertEqual(session.calls, callsBeforeReset + [
            .setCategory(.playback, .voicePrompt, [.duckOthers, .interruptSpokenAudioAndMixWithOthers]),
            .setActive(true, []),
        ])
    }

    func test_mediaServicesReset_withNoHolds_doesNotTouchTheSession() async {
        await subject.handleMediaServicesReset()

        XCTAssertEqual(session.calls, [])
    }

    // MARK: - Scoped form

    func test_withAudioFocus_holdsForTheDurationOfTheBody() async {
        await subject.withAudioFocus {
            let hasAudioFocus = await self.subject.hasAudioFocus
            XCTAssertTrue(hasAudioFocus)
        }

        let hasAudioFocus = await subject.hasAudioFocus
        XCTAssertFalse(hasAudioFocus)
        XCTAssertEqual(session.calls.last, .setActive(false, .notifyOthersOnDeactivation))
    }

    func test_withAudioFocus_releasesWhenTheBodyThrows() async {
        struct Boom: Error {}

        do {
            try await subject.withAudioFocus { throw Boom() }
            XCTFail("Expected the error to propagate")
        } catch is Boom {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let hasAudioFocus = await subject.hasAudioFocus
        XCTAssertFalse(hasAudioFocus, "A throwing body must not leak its hold")
    }

    /// Two scopes that overlap without nesting, which is what a chime and a spoken instruction
    /// actually look like.
    func test_withAudioFocus_overlappingScopesKeepSessionActiveUntilBothFinish() async {
        let chimeStarted = expectation(description: "chime acquired focus")
        let speechMayFinish = expectation(description: "speech released")

        async let speech: Void = subject.withAudioFocus {
            await fulfillment(of: [chimeStarted], timeout: 10)
        }

        async let chime: Void = subject.withAudioFocus {
            chimeStarted.fulfill()
            // Outlives the speech scope's exit.
            await fulfillment(of: [speechMayFinish], timeout: 10)
        }

        // The speech scope only returns once the chime has already acquired, so awaiting it here
        // is also how we know the two holds genuinely overlapped.
        _ = await speech

        XCTAssertFalse(
            session.calls.contains(.setActive(false, .notifyOthersOnDeactivation)),
            "The chime scope is still open"
        )

        speechMayFinish.fulfill()
        _ = await chime

        XCTAssertEqual(session.calls.last, .setActive(false, .notifyOthersOnDeactivation))
    }

    // MARK: - Concurrency

    /// Many unrelated holders arriving at once must produce exactly one activation, and exactly
    /// one deactivation once the last of them lets go.
    func test_concurrentAcquireAndRelease_activatesOnceAndDeactivatesOnce() async {
        let holderCount = 200

        var holds: [AudioFocusHold] = []
        await withTaskGroup(of: AudioFocusHold.self) { group in
            for _ in 0 ..< holderCount {
                group.addTask { await self.subject.acquireAudioFocus() }
            }
            for await hold in group {
                holds.append(hold)
            }
        }

        XCTAssertEqual(session.calls.filter { $0 == .setActive(true, []) }.count, 1)

        await withTaskGroup(of: Void.self) { group in
            for hold in holds {
                group.addTask { await self.subject.releaseAudioFocus(hold) }
            }
        }

        XCTAssertEqual(session.calls.filter { $0 == .setActive(false, .notifyOthersOnDeactivation) }.count, 1)
        let hasAudioFocus = await subject.hasAudioFocus
        XCTAssertFalse(hasAudioFocus)
    }
}
