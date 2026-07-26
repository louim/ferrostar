import AVFoundation
import Combine
import FerrostarCoreFFI
import os
import XCTest
@testable import FerrostarCore

final class MockSpeechSynthesizer: SpeechSynthesizer {
    var isSpeaking: Bool = false

    var onSpeak: ((AVSpeechUtterance) -> Void)?
    func speak(_ utterance: AVSpeechUtterance) {
        onSpeak?(utterance)
    }

    var onStopSpeaking: ((AVSpeechBoundary) -> Void)?
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        onStopSpeaking?(boundary)
        return true
    }
}

final class MockQueueObservableSpeechSynthesizer: QueueObservableSpeechSynthesizer {
    var isSpeaking: Bool = false
    var onUtteranceQueueDrained: (@Sendable () -> Void)?

    var onSpeak: ((AVSpeechUtterance) -> Void)?
    func speak(_ utterance: AVSpeechUtterance) {
        onSpeak?(utterance)
    }

    var onStopSpeaking: ((AVSpeechBoundary) -> Void)?
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        onStopSpeaking?(boundary)
        return true
    }
}

/// Records what the observer does to the shared audio session.
///
/// Injecting this is the whole point of `AudioSessionControlling`: before it existed, the
/// observer owned a private `AudioSessionManager` and nothing about audio focus — the single most
/// failure-prone part of this file — could be asserted at all.
final class SpyAudioSession: AudioSessionControlling {
    private struct State {
        var acquired: [AudioFocusHold] = []
        var released: [AudioFocusHold] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var acquiredCount: Int {
        state.withLock { $0.acquired.count }
    }

    var releasedCount: Int {
        state.withLock { $0.released.count }
    }

    var hasOutstandingHold: Bool {
        state.withLock { $0.acquired.count > $0.released.count }
    }

    /// Every release must correspond to a hold this spy actually issued.
    var releasedOnlyIssuedHolds: Bool {
        state.withLock { $0.released.allSatisfy($0.acquired.contains) }
    }

    var onAcquire: (@Sendable () -> Void)?
    var onRelease: (@Sendable () -> Void)?

    func acquireAudioFocus() async -> AudioFocusHold {
        let hold = AudioFocusHold()
        state.withLock { $0.acquired.append(hold) }
        onAcquire?()
        return hold
    }

    func releaseAudioFocus(_ hold: AudioFocusHold) async {
        state.withLock { $0.released.append(hold) }
        onRelease?()
    }
}

/// An `AVSpeechSynthesizer` that stays quiet, so tests exercising the convenience factory do not
/// depend on real synthesis.
private final class SilentAVSpeechSynthesizer: AVSpeechSynthesizer {
    override func speak(_: AVSpeechUtterance) {}

    override func stopSpeaking(at _: AVSpeechBoundary) -> Bool {
        true
    }
}

private final class RecordingSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var finished: [AVSpeechUtterance] = []

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished.append(utterance)
    }
}

private func makeInstruction(_ text: String) -> FerrostarCoreFFI.SpokenInstruction {
    .init(text: text, ssml: nil, triggerDistanceBeforeManeuver: 1.0, utteranceId: .init())
}

final class SpokenObserverTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func test_mute() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        let spokenObserver = SpokenInstructionObserver(synthesizer: mockSpeechSynthesizer, isMuted: false)

        let muteExp = expectation(description: "isMuted is set to true")
        spokenObserver.$isMuted
            .sink { newIsMuted in
                guard newIsMuted else {
                    return
                }
                muteExp.fulfill()
            }
            .store(in: &cancellables)

        let exp = expectation(description: "stop speaking is called")
        mockSpeechSynthesizer.onStopSpeaking = { boundary in
            XCTAssertEqual(boundary, .immediate)
            exp.fulfill()
        }

        spokenObserver.toggleMute()

        wait(for: [muteExp, exp], timeout: 10)
    }

    func test_speakWhileMuted() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        let spokenObserver = SpokenInstructionObserver(synthesizer: mockSpeechSynthesizer, isMuted: true)

        mockSpeechSynthesizer.onSpeak = { _ in
            XCTFail("Speak should never be called when isMuted is true")
        }

        let exp = expectation(description: "task complete")
        Task {
            spokenObserver.spokenInstructionTriggered(.init(
                text: "Speak",
                ssml: "Speak",
                triggerDistanceBeforeManeuver: 1.0,
                utteranceId: .init()
            ))
            try await Task.sleep(nanoseconds: 1_000_000_000)
            exp.fulfill()
        }

        wait(for: [exp], timeout: 10)
    }

    func test_speakWhileUnmuted() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        let spokenObserver = SpokenInstructionObserver(synthesizer: mockSpeechSynthesizer, isMuted: false)

        let exp = expectation(description: "speak is called with expected text")
        mockSpeechSynthesizer.onSpeak = { utterance in
            XCTAssertEqual(utterance.speechString, "Speak")
            exp.fulfill()
        }

        let taskExp = expectation(description: "task complete")
        Task {
            spokenObserver.spokenInstructionTriggered(.init(
                text: "Speak",
                ssml: "Speak",
                triggerDistanceBeforeManeuver: 1.0,
                utteranceId: .init()
            ))
            try await Task.sleep(nanoseconds: 1_000_000_000)
            taskExp.fulfill()
        }

        wait(for: [exp, taskExp], timeout: 10)
    }

    // MARK: - Ordering

    /// `FerrostarCore` hands spoken instructions to the observer on a *concurrent* global queue,
    /// and acquiring audio focus suspends. Without an explicit serial chain a later instruction can
    /// overtake an earlier one and the navigator announces the maneuvers out of order.
    func test_utterancesAreSpokenInTheOrderInstructionsArrive() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        let spokenObserver = SpokenInstructionObserver(synthesizer: mockSpeechSynthesizer, isMuted: false)

        let instructionCount = 25
        let expected = (0 ..< instructionCount).map { "Instruction \($0)" }

        let spoken = OSAllocatedUnfairLock(initialState: [String]())
        let exp = expectation(description: "every instruction is spoken")
        mockSpeechSynthesizer.onSpeak = { utterance in
            let text = utterance.speechString
            let isComplete = spoken.withLock { spoken -> Bool in
                spoken.append(text)
                return spoken.count == instructionCount
            }
            if isComplete {
                exp.fulfill()
            }
        }

        for text in expected {
            spokenObserver.spokenInstructionTriggered(makeInstruction(text))
        }

        wait(for: [exp], timeout: 10)
        XCTAssertEqual(spoken.withLock { $0 }, expected)
    }

    // MARK: - Drain edge wiring

    func test_drainHandlerIsInstalledOnAQueueObservableSynthesizer() {
        let mockSpeechSynthesizer = MockQueueObservableSpeechSynthesizer()
        XCTAssertNil(mockSpeechSynthesizer.onUtteranceQueueDrained)

        var spokenObserver: SpokenInstructionObserver? =
            SpokenInstructionObserver(synthesizer: mockSpeechSynthesizer, isMuted: false)
        XCTAssertNotNil(spokenObserver)
        XCTAssertNotNil(mockSpeechSynthesizer.onUtteranceQueueDrained)

        // The synthesizer is frequently owned by the host app and outlives the observer.
        spokenObserver = nil
        XCTAssertNil(
            mockSpeechSynthesizer.onUtteranceQueueDrained,
            "A released observer must not leave a handler behind on a synthesizer it does not own"
        )
    }

    /// A drain edge arriving after the observer is gone must be inert rather than a crash.
    func test_drainEdgeAfterObserverIsReleased_isANoOp() {
        let mockSpeechSynthesizer = MockQueueObservableSpeechSynthesizer()
        var spokenObserver: SpokenInstructionObserver? =
            SpokenInstructionObserver(synthesizer: mockSpeechSynthesizer, isMuted: false)

        // Capture the handler while the observer is alive, mimicking a callback already in flight
        // when the observer goes away.
        let handler = mockSpeechSynthesizer.onUtteranceQueueDrained
        XCTAssertNotNil(handler)
        XCTAssertNotNil(spokenObserver)

        spokenObserver = nil

        handler?()
    }

    /// A drain edge that lands while audio is still playing must leave the fallback poll armed,
    /// because the poll is then the only thing that will retry the release.
    ///
    /// This pins the ordering of the guard and `cancelAudioFocusRelease()` inside
    /// `releaseAudioFocus()`, which otherwise reads like a redundant early return. It is
    /// load-bearing for `stopSpeaking(at: .word)`: that zeroes the queue count without publishing
    /// a drain edge, so nothing else would ever release focus. Hoist the cancel above the guard
    /// and this test fails.
    func test_drainEdgeArrivingWhileStillSpeaking_leavesTheFallbackPollArmed() {
        let mockSpeechSynthesizer = MockQueueObservableSpeechSynthesizer()
        // Audio outlives the queue count, exactly as it does after a `.word` boundary stop.
        mockSpeechSynthesizer.isSpeaking = true

        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            maximumAudioFocusHold: .milliseconds(1)
        )

        let exp = expectation(description: "the fallback poll still fires")
        exp.assertForOverFulfill = false
        mockSpeechSynthesizer.onStopSpeaking = { boundary in
            XCTAssertEqual(boundary, .immediate)
            exp.fulfill()
        }

        mockSpeechSynthesizer.onSpeak = { [weak mockSpeechSynthesizer] _ in
            mockSpeechSynthesizer?.onUtteranceQueueDrained?()
        }

        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))

        wait(for: [exp], timeout: 10)
    }

    // MARK: - Stalled speech recovery

    /// The field failure this whole change exists for: an utterance cut without a completion
    /// callback leaves `isSpeaking` stuck at `true`, so every later instruction queues behind a
    /// dead one and guidance goes silent for the rest of the trip with nothing on screen to
    /// explain it. Only flushing the queue recovers it.
    func test_synthesizerStuckSpeaking_isRecoveredAfterMaximumAudioFocusHold() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        // Never goes false again, exactly as a wedged AVSpeechSynthesizer behaves.
        mockSpeechSynthesizer.isSpeaking = true

        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            maximumAudioFocusHold: .milliseconds(1)
        )

        let exp = expectation(description: "the stalled queue is flushed")
        mockSpeechSynthesizer.onStopSpeaking = { boundary in
            XCTAssertEqual(boundary, .immediate, "Only .immediate flushes a wedged queue")
            exp.fulfill()
        }

        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))

        wait(for: [exp], timeout: 10)
    }

    /// The recovery must not fire for a synthesizer that simply finishes normally.
    func test_synthesizerThatStopsSpeaking_isNotFlushed() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        mockSpeechSynthesizer.isSpeaking = false

        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            maximumAudioFocusHold: .milliseconds(1)
        )

        mockSpeechSynthesizer.onStopSpeaking = { _ in
            XCTFail("A synthesizer that reports it finished must never have its queue flushed")
        }

        let exp = expectation(description: "the instruction is spoken")
        mockSpeechSynthesizer.onSpeak = { _ in exp.fulfill() }

        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))

        wait(for: [exp], timeout: 10)
        // Outlive several poll ticks so a spurious flush would be caught.
        Thread.sleep(forTimeInterval: 2)
    }

    // MARK: - Default synthesizer

    /// The default path must get the queue-tracking behaviour without any code change by the host,
    /// and must not silently steal a delegate the host already installed.
    func test_initAVSpeechSynthesizer_wrapsInQueueTrackingSynthesizer() {
        let avSpeechSynthesizer = AVSpeechSynthesizer()
        let hostDelegate = RecordingSpeechDelegate()
        avSpeechSynthesizer.delegate = hostDelegate

        let spokenObserver = SpokenInstructionObserver.initAVSpeechSynthesizer(synthesizer: avSpeechSynthesizer)

        let tracking = spokenObserver.synthesizer as? QueueTrackingSpeechSynthesizer
        XCTAssertNotNil(tracking, "The default synthesizer must be queue-observable")
        XCTAssertTrue(avSpeechSynthesizer.delegate === tracking, "The wrapper must own the delegate slot")
        XCTAssertTrue(tracking?.forwardingDelegate === hostDelegate, "The host's delegate must be preserved")
    }

    /// The convenience factory must be able to join a shared session too, otherwise an app that
    /// uses it has no way to stop its own sounds from fighting Ferrostar's.
    func test_initAVSpeechSynthesizer_forwardsTheAudioSession() {
        let spyAudioSession = SpyAudioSession()
        let spokenObserver = SpokenInstructionObserver.initAVSpeechSynthesizer(
            synthesizer: SilentAVSpeechSynthesizer(),
            audioSession: spyAudioSession
        )

        let exp = expectation(description: "audio focus acquired from the injected session")
        exp.assertForOverFulfill = false
        spyAudioSession.onAcquire = { exp.fulfill() }

        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))

        wait(for: [exp], timeout: 10)
    }

    // MARK: - Audio focus

    /// Guidance is a single continuous claim, not one per instruction. Acquiring repeatedly would
    /// leave holds outstanding that nothing ever releases, ducking every other app indefinitely.
    func test_consecutiveInstructionsShareOneAudioFocusHold() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        let spyAudioSession = SpyAudioSession()
        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            audioSession: spyAudioSession
        )

        let exp = expectation(description: "all instructions spoken")
        let spokenCount = OSAllocatedUnfairLock(initialState: 0)
        mockSpeechSynthesizer.onSpeak = { _ in
            let isComplete = spokenCount.withLock { count -> Bool in
                count += 1
                return count == 3
            }
            if isComplete {
                exp.fulfill()
            }
        }

        // Still "speaking" throughout, so nothing concludes the queue has drained.
        mockSpeechSynthesizer.isSpeaking = true
        for text in ["One", "Two", "Three"] {
            spokenObserver.spokenInstructionTriggered(makeInstruction(text))
        }

        wait(for: [exp], timeout: 10)
        XCTAssertEqual(spyAudioSession.acquiredCount, 1)
        XCTAssertEqual(spyAudioSession.releasedCount, 0)
    }

    func test_audioFocusIsReleasedOnTheDrainEdge() {
        let mockSpeechSynthesizer = MockQueueObservableSpeechSynthesizer()
        let spyAudioSession = SpyAudioSession()
        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            audioSession: spyAudioSession
        )

        let exp = expectation(description: "audio focus released")
        spyAudioSession.onRelease = { exp.fulfill() }

        mockSpeechSynthesizer.onSpeak = { [weak mockSpeechSynthesizer] _ in
            // The queue drained; the synthesizer is genuinely idle now.
            mockSpeechSynthesizer?.isSpeaking = false
            mockSpeechSynthesizer?.onUtteranceQueueDrained?()
        }

        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))

        wait(for: [exp], timeout: 10)
        XCTAssertEqual(spyAudioSession.acquiredCount, 1)
        XCTAssertEqual(spyAudioSession.releasedCount, 1)
        XCTAssertTrue(spyAudioSession.releasedOnlyIssuedHolds)
        XCTAssertFalse(spyAudioSession.hasOutstandingHold)
    }

    /// The failure this whole area exists to prevent: releasing focus deactivates the session, and
    /// doing that under a live utterance cuts it without a completion callback.
    func test_audioFocusIsNotReleasedWhileStillSpeaking() {
        let mockSpeechSynthesizer = MockQueueObservableSpeechSynthesizer()
        // Audio is still playing when the edge arrives.
        mockSpeechSynthesizer.isSpeaking = true

        let spyAudioSession = SpyAudioSession()
        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            // Long enough that the watchdog cannot confound this.
            maximumAudioFocusHold: .seconds(600),
            audioSession: spyAudioSession
        )

        let exp = expectation(description: "instruction spoken")
        mockSpeechSynthesizer.onSpeak = { [weak mockSpeechSynthesizer] _ in
            mockSpeechSynthesizer?.onUtteranceQueueDrained?()
            exp.fulfill()
        }

        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))
        wait(for: [exp], timeout: 10)

        // Outlive several fallback poll ticks; a premature release would land in this window.
        Thread.sleep(forTimeInterval: 2)

        XCTAssertEqual(spyAudioSession.acquiredCount, 1)
        XCTAssertEqual(spyAudioSession.releasedCount, 0, "Releasing here would cut the live utterance")
    }

    func test_stalledSpeechRecoveryReleasesAudioFocus() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        // Never stops, exactly as a wedged AVSpeechSynthesizer behaves.
        mockSpeechSynthesizer.isSpeaking = true

        let spyAudioSession = SpyAudioSession()
        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            maximumAudioFocusHold: .milliseconds(1),
            audioSession: spyAudioSession
        )

        let exp = expectation(description: "audio focus released")
        exp.assertForOverFulfill = false
        spyAudioSession.onRelease = { exp.fulfill() }

        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))

        wait(for: [exp], timeout: 10)
        XCTAssertTrue(spyAudioSession.releasedOnlyIssuedHolds)
        XCTAssertFalse(spyAudioSession.hasOutstandingHold)
    }

    func test_stopAndClearQueueReleasesAudioFocus() {
        let mockSpeechSynthesizer = MockSpeechSynthesizer()
        mockSpeechSynthesizer.isSpeaking = true

        let spyAudioSession = SpyAudioSession()
        let spokenObserver = SpokenInstructionObserver(
            synthesizer: mockSpeechSynthesizer,
            isMuted: false,
            maximumAudioFocusHold: .seconds(600),
            audioSession: spyAudioSession
        )

        let spoken = expectation(description: "instruction spoken")
        mockSpeechSynthesizer.onSpeak = { _ in spoken.fulfill() }
        spokenObserver.spokenInstructionTriggered(makeInstruction("Turn left"))
        wait(for: [spoken], timeout: 10)

        let released = expectation(description: "audio focus released")
        released.assertForOverFulfill = false
        spyAudioSession.onRelease = { released.fulfill() }

        spokenObserver.stopAndClearQueue()

        wait(for: [released], timeout: 10)
        XCTAssertFalse(spyAudioSession.hasOutstandingHold)
    }
}
