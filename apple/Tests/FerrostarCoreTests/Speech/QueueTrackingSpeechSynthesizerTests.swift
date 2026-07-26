import AVFoundation
import os
import XCTest
@testable import FerrostarCore

/// An `AVSpeechSynthesizer` that records instead of synthesizing.
///
/// Subclassing (rather than introducing a protocol seam in the production type) keeps
/// ``QueueTrackingSpeechSynthesizer`` able to own a real `delegate`, which is the whole point of
/// the type, while keeping the tests silent and deterministic.
private final class FakeAVSpeechSynthesizer: AVSpeechSynthesizer {
    /// The subject is exercised from many threads at once, so the recording has to be guarded.
    /// `AVSpeechUtterance` is not `Sendable`, hence a plain lock rather than `OSAllocatedUnfairLock`.
    private let recordingLock = NSLock()
    private var _spokenUtterances: [AVSpeechUtterance] = []
    private var _stopBoundaries: [AVSpeechBoundary] = []

    var spokenUtterances: [AVSpeechUtterance] {
        recordingLock.withLock { _spokenUtterances }
    }

    var stopBoundaries: [AVSpeechBoundary] {
        recordingLock.withLock { _stopBoundaries }
    }

    /// Stands in for the real `isSpeaking`, which is driven by the audio engine.
    var isSpeakingOverride = false
    var stopReturnValue = true

    override var isSpeaking: Bool {
        isSpeakingOverride
    }

    override func speak(_ utterance: AVSpeechUtterance) {
        recordingLock.withLock { _spokenUtterances.append(utterance) }
    }

    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        recordingLock.withLock { _stopBoundaries.append(boundary) }
        return stopReturnValue
    }
}

private final class SpyDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var finished: [AVSpeechUtterance] = []
    private(set) var cancelled: [AVSpeechUtterance] = []
    private(set) var started: [AVSpeechUtterance] = []

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished.append(utterance)
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        cancelled.append(utterance)
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        started.append(utterance)
    }
}

final class QueueTrackingSpeechSynthesizerTests: XCTestCase {
    private var fake: FakeAVSpeechSynthesizer!
    private var subject: QueueTrackingSpeechSynthesizer!

    override func setUp() {
        super.setUp()
        fake = FakeAVSpeechSynthesizer()
        subject = QueueTrackingSpeechSynthesizer(synthesizer: fake)
    }

    override func tearDown() {
        subject = nil
        fake = nil
        super.tearDown()
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        AVSpeechUtterance(string: text)
    }

    // MARK: - Queue accounting

    /// `AVSpeechSynthesizer` does not begin synthesis synchronously. If the wrapper only counted
    /// utterances once speech actually started, the observer's release poll could sample the gap
    /// in between and deactivate the session before a word was spoken.
    func test_isSpeaking_isTrueFromEnqueue_beforeSynthesisStarts() {
        XCTAssertFalse(subject.isSpeaking)

        subject.speak(utterance("Turn left"))

        XCTAssertTrue(subject.isSpeaking)
        XCTAssertFalse(fake.isSpeakingOverride, "Precondition: the underlying synthesizer has not started")
        XCTAssertEqual(fake.spokenUtterances.count, 1)
    }

    /// This is the ferrostar#751 gap: `AVSpeechSynthesizer.isSpeaking` reports `false` between two
    /// chained utterances, and turn-by-turn navigation chains utterances constantly.
    func test_isSpeaking_remainsTrueWhenOneOfTwoChainedUtterancesFinishes() {
        let first = utterance("Turn left")
        let second = utterance("Then turn right")

        subject.speak(first)
        subject.speak(second)

        subject.speechSynthesizer(fake, didFinish: first)

        XCTAssertTrue(subject.isSpeaking, "One of two utterances is still outstanding")
    }

    func test_isSpeaking_isFalseOnceQueueDrains() {
        let first = utterance("Turn left")
        let second = utterance("Then turn right")

        subject.speak(first)
        subject.speak(second)
        subject.speechSynthesizer(fake, didFinish: first)
        subject.speechSynthesizer(fake, didFinish: second)

        XCTAssertFalse(subject.isSpeaking)
    }

    func test_didCancel_drainsTheQueue() {
        let only = utterance("Turn left")

        subject.speak(only)
        subject.speechSynthesizer(fake, didCancel: only)

        XCTAssertFalse(subject.isSpeaking)
    }

    /// Utterances that never began synthesis do not reliably deliver `didCancel`, so the count has
    /// to be reset explicitly. Without this the count sticks above zero forever and every other
    /// app on the device stays ducked.
    func test_stopSpeakingImmediate_resetsCount_withoutPerUtteranceCallbacks() {
        subject.speak(utterance("Turn left"))
        subject.speak(utterance("Then turn right"))
        XCTAssertTrue(subject.isSpeaking)

        subject.stopSpeaking(at: .immediate)

        XCTAssertFalse(subject.isSpeaking)
        XCTAssertEqual(fake.stopBoundaries, [.immediate])
    }

    /// A `didCancel` that arrives after the reset must not push the count negative; if it did, the
    /// next utterance would read as idle and the observer would release focus while it spoke.
    func test_lateDidCancelAfterStop_doesNotUnderflow() {
        let stale = utterance("Turn left")
        subject.speak(stale)
        subject.stopSpeaking(at: .immediate)

        // Arrives late, for an utterance already accounted for by the reset.
        subject.speechSynthesizer(fake, didCancel: stale)
        XCTAssertFalse(subject.isSpeaking)

        subject.speak(utterance("Fresh instruction"))
        XCTAssertTrue(subject.isSpeaking, "A fresh utterance must not be masked by an underflowed count")
    }

    /// The wrapper cannot see utterances enqueued directly on the synthesizer it wraps, so
    /// `isSpeaking` also consults the underlying value. Reporting "idle" while audio is playing is
    /// the mistake that wedges the session.
    func test_isSpeaking_fallsBackToUnderlyingSynthesizer() {
        XCTAssertFalse(subject.isSpeaking)

        fake.isSpeakingOverride = true

        XCTAssertTrue(subject.isSpeaking)
    }

    // MARK: - Drain edge

    func test_drainEdge_firesOnlyWhenTheQueueFullyEmpties() {
        let first = utterance("Turn left")
        let second = utterance("Then turn right")

        let drainCount = OSAllocatedUnfairLock(initialState: 0)
        subject.onUtteranceQueueDrained = { drainCount.withLock { $0 += 1 } }

        subject.speak(first)
        subject.speak(second)
        XCTAssertEqual(drainCount.withLock { $0 }, 0)

        subject.speechSynthesizer(fake, didFinish: first)
        XCTAssertEqual(drainCount.withLock { $0 }, 0, "Mid-queue completion is not a drain")

        subject.speechSynthesizer(fake, didFinish: second)
        XCTAssertEqual(drainCount.withLock { $0 }, 1)
    }

    func test_drainEdge_doesNotFireForCallbacksArrivingOnAnEmptyQueue() {
        let drainCount = OSAllocatedUnfairLock(initialState: 0)
        subject.onUtteranceQueueDrained = { drainCount.withLock { $0 += 1 } }

        subject.speechSynthesizer(fake, didFinish: utterance("Never enqueued here"))

        XCTAssertEqual(drainCount.withLock { $0 }, 0)
    }

    func test_stopSpeakingImmediate_emitsDrainEdge() {
        let drainCount = OSAllocatedUnfairLock(initialState: 0)
        subject.onUtteranceQueueDrained = { drainCount.withLock { $0 += 1 } }

        subject.speak(utterance("Turn left"))
        subject.stopSpeaking(at: .immediate)

        XCTAssertEqual(drainCount.withLock { $0 }, 1)
    }

    /// At a `.word` boundary the current utterance is still being spoken. Announcing a drain would
    /// invite the observer to deactivate the session underneath it — the exact failure this type
    /// exists to prevent. Release is left to the observer's fallback poll.
    func test_stopSpeakingAtWordBoundary_doesNotEmitDrainEdge() {
        let drainCount = OSAllocatedUnfairLock(initialState: 0)
        subject.onUtteranceQueueDrained = { drainCount.withLock { $0 += 1 } }

        subject.speak(utterance("Turn left"))
        fake.isSpeakingOverride = true
        subject.stopSpeaking(at: .word)

        XCTAssertEqual(drainCount.withLock { $0 }, 0)
        XCTAssertTrue(subject.isSpeaking, "Still speaking until the word boundary is reached")
    }

    func test_stopSpeaking_onAnAlreadyEmptyQueue_doesNotEmitDrainEdge() {
        let drainCount = OSAllocatedUnfairLock(initialState: 0)
        subject.onUtteranceQueueDrained = { drainCount.withLock { $0 += 1 } }

        subject.stopSpeaking(at: .immediate)

        XCTAssertEqual(drainCount.withLock { $0 }, 0)
    }

    // MARK: - Delegate forwarding

    func test_existingDelegateIsPreservedAndForwarded() {
        let spy = SpyDelegate()
        let synthesizer = FakeAVSpeechSynthesizer()
        synthesizer.delegate = spy

        let wrapper = QueueTrackingSpeechSynthesizer(synthesizer: synthesizer)

        XCTAssertTrue(wrapper.forwardingDelegate === spy, "A delegate set before wrapping must be preserved")
        XCTAssertTrue(synthesizer.delegate === wrapper, "The wrapper must own the delegate slot")

        let first = AVSpeechUtterance(string: "Turn left")
        let second = AVSpeechUtterance(string: "Then turn right")
        wrapper.speechSynthesizer(synthesizer, didStart: first)
        wrapper.speechSynthesizer(synthesizer, didFinish: first)
        wrapper.speechSynthesizer(synthesizer, didCancel: second)

        XCTAssertEqual(spy.started, [first])
        XCTAssertEqual(spy.finished, [first])
        XCTAssertEqual(spy.cancelled, [second])
    }

    /// The host application usually owns the `AVSpeechSynthesizer` and keeps using it after
    /// navigation ends. It must not silently lose its own delegate callbacks.
    func test_delegateSlotIsHandedBackOnDeinit() {
        let spy = SpyDelegate()
        let synthesizer = FakeAVSpeechSynthesizer()
        synthesizer.delegate = spy

        do {
            let wrapper = QueueTrackingSpeechSynthesizer(synthesizer: synthesizer)
            XCTAssertTrue(synthesizer.delegate === wrapper)
        }

        XCTAssertTrue(synthesizer.delegate === spy, "The original delegate must be restored")
    }

    func test_delegateSlotIsNotClobberedIfSomebodyElseTookItOver() {
        let original = SpyDelegate()
        let usurper = SpyDelegate()
        let synthesizer = FakeAVSpeechSynthesizer()
        synthesizer.delegate = original

        var wrapper: QueueTrackingSpeechSynthesizer? = QueueTrackingSpeechSynthesizer(synthesizer: synthesizer)
        XCTAssertTrue(synthesizer.delegate === wrapper)

        synthesizer.delegate = usurper
        wrapper = nil

        XCTAssertTrue(synthesizer.delegate === usurper, "A delegate installed after wrapping must survive")
    }

    func test_forwardingDelegateIsHeldWeakly() {
        var spy: SpyDelegate? = SpyDelegate()
        let synthesizer = FakeAVSpeechSynthesizer()
        synthesizer.delegate = spy

        let wrapper = QueueTrackingSpeechSynthesizer(synthesizer: synthesizer)
        XCTAssertNotNil(wrapper.forwardingDelegate)

        spy = nil

        XCTAssertNil(wrapper.forwardingDelegate, "The wrapper must not keep the host app's delegate alive")
        // Forwarding to a deallocated delegate must be a no-op rather than a crash.
        wrapper.speechSynthesizer(synthesizer, didFinish: AVSpeechUtterance(string: "Turn left"))
    }

    // MARK: - Concurrency

    /// `speak` runs on the observer's tasks, the delegate callbacks arrive on AVFoundation's queue,
    /// and `isSpeaking` is read by the fallback poll. Enqueue and drain the same number of times
    /// from many threads and the count must land back on exactly zero.
    func test_concurrentEnqueueAndDrain_settlesAtZero() {
        let iterations = 500
        let utterances = (0 ..< iterations).map { AVSpeechUtterance(string: "Instruction \($0)") }

        // Enqueue everything first so that no drain can outrun its own `speak` and be clamped
        // away, which would leave a non-zero count for reasons unrelated to thread safety.
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            self.subject.speak(utterances[index])
        }
        XCTAssertTrue(subject.isSpeaking)

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            self.subject.speechSynthesizer(self.fake, didFinish: utterances[index])
        }

        XCTAssertFalse(subject.isSpeaking, "Every enqueue was matched by exactly one drain")
    }

    /// The drain edge is what releases audio focus. Firing it more than once per drain would be
    /// tolerable; firing it zero times would leave other apps ducked.
    func test_concurrentDrain_firesTheDrainEdgeExactlyOnce() {
        let iterations = 200
        let utterances = (0 ..< iterations).map { AVSpeechUtterance(string: "Instruction \($0)") }

        let drainCount = OSAllocatedUnfairLock(initialState: 0)
        subject.onUtteranceQueueDrained = { drainCount.withLock { $0 += 1 } }

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            self.subject.speak(utterances[index])
        }
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            self.subject.speechSynthesizer(self.fake, didFinish: utterances[index])
        }

        XCTAssertEqual(drainCount.withLock { $0 }, 1)
    }
}
