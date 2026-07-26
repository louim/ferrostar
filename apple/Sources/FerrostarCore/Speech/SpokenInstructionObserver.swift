import AVFoundation
import Combine
import FerrostarCoreFFI
import Foundation
import os

private let logger = Logger(subsystem: "com.stadiamaps.ferrostar", category: "SpokenInstructionObserver")

/// An Spoken instruction provider that triggers speech synthesis in response to navigation events.
///
/// Automatically handles audio session management,
/// including ducking volume from other apps when appropriate.
///
/// ## Audio focus lifetime
///
/// Focus is acquired before the first utterance and released once the synthesizer's queue drains.
/// Getting the release moment wrong is not a cosmetic problem:
/// deactivating the audio session while an utterance is still being spoken cuts that utterance
/// without delivering a completion callback,
/// after which `AVSpeechSynthesizer.isSpeaking` stays `true` forever
/// and every later instruction queues silently behind the dead one.
///
/// When the injected synthesizer conforms to ``QueueObservableSpeechSynthesizer``
/// — which ``QueueTrackingSpeechSynthesizer``, the default, does —
/// the release is driven by an explicit drain edge from the synthesizer.
/// Otherwise it falls back to polling ``SpeechSynthesizer/isSpeaking``,
/// which cannot distinguish "finished" from "between two chained utterances".
public class SpokenInstructionObserver {
    @Published public private(set) var isMuted: Bool

    let synthesizer: SpeechSynthesizer
    private let audioManager = AudioSessionManager()
    private let maximumAudioFocusHold: Duration

    private struct State {
        /// Tail of the serial chain that all speech work is threaded through.
        var speechTail: Task<Void, Never>?
        /// The in-flight fallback poll, if any.
        var releaseTask: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates a spoken instruction observer with any ``SpeechSynthesizer``.
    ///
    /// - Parameters:
    ///   - synthesizer: The speech synthesizer.
    ///     Conform it to ``QueueObservableSpeechSynthesizer``
    ///     (or use ``QueueTrackingSpeechSynthesizer``) for correct audio focus release;
    ///     see the note on ``SpokenInstructionObserver`` for what a bare synthesizer gives up.
    ///   - isMuted: Whether the speech synthesizer is currently muted. Assume false if unknown.
    ///   - maximumAudioFocusHold: An upper bound on how long focus is held after the most recent
    ///     utterance is enqueued. This is a safety valve, not a schedule: it only takes effect if
    ///     the synthesizer never reports that it stopped speaking, which in practice means an
    ///     utterance was cut without a completion callback. When it elapses the synthesizer's queue
    ///     is flushed and focus released, so guidance recovers on its own instead of staying silent
    ///     for the rest of the trip.
    public init(
        synthesizer: SpeechSynthesizer,
        isMuted: Bool,
        maximumAudioFocusHold: Duration = .seconds(60)
    ) {
        self.synthesizer = synthesizer
        self.isMuted = isMuted
        self.maximumAudioFocusHold = maximumAudioFocusHold

        if let observable = synthesizer as? any QueueObservableSpeechSynthesizer {
            // Weak, and the synthesizer may outlive us: a dead handler is a no-op.
            observable.onUtteranceQueueDrained = { [weak self] in
                self?.handleUtteranceQueueDrained()
            }
        }
    }

    deinit {
        // The synthesizer can be owned by the host app and outlive this observer.
        (synthesizer as? any QueueObservableSpeechSynthesizer)?.onUtteranceQueueDrained = nil

        let tasks = state.withLock { state -> [Task<Void, Never>] in
            let tasks = [state.speechTail, state.releaseTask].compactMap { $0 }
            state.speechTail = nil
            state.releaseTask = nil
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
        // NOTE: The tasks will deinit themselves
    }

    public func spokenInstructionTriggered(_ instruction: FerrostarCoreFFI.SpokenInstruction) {
        guard !isMuted else {
            return
        }

        enqueueSerially { [weak self] in
            guard let self, !self.isMuted else {
                // The user may have muted between the check above and this work item running.
                return
            }

            // Built here rather than at the call site: `AVSpeechUtterance` is not `Sendable`, and
            // this way it is created and consumed entirely within one work item.
            let utterance = Self.utterance(for: instruction)

            cancelAudioFocusRelease()
            await audioManager.requestAudioFocus()
            synthesizer.speak(utterance)
            scheduleFallbackAudioFocusRelease()
        }
    }

    /// Toggle the mute.
    public func toggleMute() {
        let isCurrentlyMuted = isMuted
        isMuted = !isCurrentlyMuted

        // This used to have `synthesizer.isSpeaking`, but I think we want to run it regardless.
        if isMuted {
            stopAndClearQueue()
        }
    }

    public func stopAndClearQueue() {
        cancelAudioFocusRelease()

        enqueueSerially { [weak self] in
            guard let self else { return }

            synthesizer.stopSpeaking(at: .immediate)
            await audioManager.releaseAudioFocus()
        }
    }

    private static func utterance(for instruction: FerrostarCoreFFI.SpokenInstruction) -> AVSpeechUtterance {
        if #available(iOS 16.0, *),
           let ssml = instruction.ssml,
           let ssmlUtterance = AVSpeechUtterance(ssmlRepresentation: ssml)
        {
            ssmlUtterance
        } else {
            AVSpeechUtterance(string: instruction.text)
        }
    }

    /// Appends `work` to a serial chain, preserving the order in which callers arrive.
    ///
    /// `FerrostarCore` dispatches spoken instructions onto a *concurrent* global queue, so two
    /// instructions genuinely can be handled at once. Left unserialised, the suspension point at
    /// `requestAudioFocus()` lets a later instruction overtake an earlier one — the navigator
    /// would announce "then turn right" before the "turn left" it follows — and leaves the audio
    /// focus bookkeeping interleaved between two tasks.
    ///
    /// Releases run through the same chain, which is what lets them re-check whether speech has
    /// resumed before deactivating the session.
    ///
    /// Awaiting the previous task (rather than spawning freely) is what provides the ordering;
    /// the lock only makes the swap of the tail itself atomic.
    private func enqueueSerially(_ work: @escaping @Sendable () async -> Void) {
        state.withLock { state in
            let previous = state.speechTail
            state.speechTail = Task {
                await previous?.value
                await work()
            }
        }
    }

    /// Handles the drain edge published by a ``QueueObservableSpeechSynthesizer``.
    private func handleUtteranceQueueDrained() {
        releaseAudioFocus()
    }

    /// Releases audio focus, but only once it is safe to do so.
    ///
    /// Every caller here has decided *at some earlier moment* that speech was finished, and an
    /// instruction can arrive between that decision and this running. So the release is threaded
    /// through the same serial chain as the speech itself and the "is it still speaking?" question
    /// is asked again from inside it. Deactivating the session under a live utterance is precisely
    /// what cuts the utterance without a completion callback and wedges all later guidance.
    private func releaseAudioFocus() {
        enqueueSerially { [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }

            cancelAudioFocusRelease()
            await audioManager.releaseAudioFocus()
        }
    }

    /// Last resort for a synthesizer that has claimed to be speaking past ``maximumAudioFocusHold``.
    ///
    /// A synthesizer whose utterance was cut without a completion callback reports `isSpeaking` as
    /// `true` forever, and every later instruction queues silently behind the dead one — guidance
    /// is gone, with nothing on screen to say why. `stopSpeaking(at: .immediate)` is the only thing
    /// that flushes that queue, so clearing it here is what makes the condition *recoverable*
    /// rather than merely bounded.
    ///
    /// The cost is cutting a genuinely long utterance short. Navigation instructions run to
    /// seconds, not a minute, so trading at most one of them for the return of all subsequent
    /// guidance is the right side of that bargain.
    private func recoverFromStalledSpeech() {
        enqueueSerially { [weak self] in
            guard let self else { return }

            synthesizer.stopSpeaking(at: .immediate)
            cancelAudioFocusRelease()
            await audioManager.releaseAudioFocus()
        }
    }

    /// Starts (or restarts) the poll that releases audio focus if no drain edge ever arrives.
    ///
    /// For a ``QueueObservableSpeechSynthesizer`` this is redundant in the normal case and exists
    /// only to bound how long focus can be held. For a bare `AVSpeechSynthesizer` it is the only
    /// release mechanism available.
    private func scheduleFallbackAudioFocusRelease() {
        let deadline = ContinuousClock.now.advanced(by: maximumAudioFocusHold)

        let task = Task { [weak self] in
            var didExceedDeadline = false

            while true {
                try? await Task.sleep(for: .milliseconds(500))

                guard !Task.isCancelled, let self else { return }
                guard synthesizer.isSpeaking else { break }

                if ContinuousClock.now >= deadline {
                    logger
                        .warning(
                            "Speech synthesizer still reports speaking after \(maximumAudioFocusHold, privacy: .public); clearing its queue and releasing audio focus. This usually means an utterance was cut without a completion callback."
                        )
                    didExceedDeadline = true
                    break
                }
            }

            guard !Task.isCancelled, let self else { return }

            if didExceedDeadline {
                recoverFromStalledSpeech()
            } else {
                releaseAudioFocus()
            }
        }

        let previous = state.withLock { state -> Task<Void, Never>? in
            let previous = state.releaseTask
            state.releaseTask = task
            return previous
        }
        previous?.cancel()
    }

    private func cancelAudioFocusRelease() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.releaseTask
            state.releaseTask = nil
            return task
        }
        task?.cancel()
    }
}

public extension SpokenInstructionObserver {
    /// Create a new spoken instruction observer with AFFoundation's AVSpeechSynthesizer.
    ///
    /// The synthesizer is wrapped in a ``QueueTrackingSpeechSynthesizer`` so that audio focus is
    /// released on an explicit drain edge rather than a poll. Any delegate already installed on
    /// `synthesizer` keeps receiving its callbacks.
    ///
    /// - Parameters:
    ///    - synthesizer: An instance of AVSpeechSynthesizer. One is provided by default, but you can inject your own.
    ///    - isMuted: If the synthesizer is muted. This should be false unless you're providing a "hot" synth that is
    /// speaking.
    /// - Returns: The instance of SpokenInstructionObserver
    static func initAVSpeechSynthesizer(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
                                        isMuted: Bool = false) -> SpokenInstructionObserver
    {
        SpokenInstructionObserver(
            synthesizer: QueueTrackingSpeechSynthesizer(synthesizer: synthesizer),
            isMuted: isMuted
        )
    }
}
