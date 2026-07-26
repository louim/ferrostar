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
}
