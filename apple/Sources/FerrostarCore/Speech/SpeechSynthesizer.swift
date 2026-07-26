import AVFoundation
import Foundation
import os

/// An abstracted speech synthesizer that is used by the ``SpokenInstructionObserver``
///
/// Any functions that are needed for use in the ``SpokenInstructionObserver`` should be exposed through
/// this protocol.
public protocol SpeechSynthesizer {
    // TODO: We could further abstract this to allow other speech synths.
    //       E.g. with a `struct SpeechUtterance` if and when another speech service comes along.

    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

/// A ``SpeechSynthesizer`` that reports the moment its utterance queue becomes empty.
///
/// ## Why this exists
///
/// ``SpokenInstructionObserver`` holds audio focus
/// (ducking other apps, interrupting spoken audio)
/// only for as long as it is actually speaking.
/// Deciding when to *release* that focus is the hard part.
///
/// Without this protocol the only available signal is ``SpeechSynthesizer/isSpeaking``,
/// which has to be polled,
/// and which `AVSpeechSynthesizer` reports as `false` in the gap *between* chained utterances.
/// Turn-by-turn navigation chains utterances constantly,
/// so a poll routinely observes one of those false gaps and releases focus mid-queue.
/// Deactivating the audio session under a live utterance cuts that utterance
/// *without* delivering a completion callback,
/// which leaves `AVSpeechSynthesizer.isSpeaking` stuck at `true` indefinitely
/// and silently wedges every instruction that follows.
/// See [stadiamaps/ferrostar#751](https://github.com/stadiamaps/ferrostar/issues/751).
///
/// Conforming lets the observer release focus on an *edge* supplied by the synthesizer
/// rather than inferring one from a poll.
/// ``QueueTrackingSpeechSynthesizer`` is the built-in conformance;
/// implement this yourself only if you are bridging a non-AVFoundation speech engine.
public protocol QueueObservableSpeechSynthesizer: AnyObject, SpeechSynthesizer {
    /// Invoked when the synthesizer's utterance queue transitions from non-empty to empty.
    ///
    /// ``SpokenInstructionObserver`` installs its own handler here and relies on it,
    /// so this is not a general-purpose hook for host applications;
    /// use ``QueueTrackingSpeechSynthesizer/forwardingDelegate`` for that.
    ///
    /// Conformances must invoke the handler *without* holding any internal lock,
    /// because it calls back into the observer.
    var onUtteranceQueueDrained: (@Sendable () -> Void)? { get set }
}

/// An `AVSpeechSynthesizer` wrapper that knows how many utterances are still outstanding.
///
/// This is the synthesizer ``SpokenInstructionObserver`` uses by default.
/// It exists because `AVSpeechSynthesizer.isSpeaking` cannot answer the only question
/// that matters for audio-session lifetime — *"is the queue empty yet?"* —
/// and because `AVSpeechSynthesizer` has a single `delegate` slot
/// that a library must not silently steal from its host application.
///
/// Two behaviours make the bookkeeping trustworthy:
///
/// - An utterance counts as outstanding from the instant it is *enqueued*,
///   not from the instant synthesis begins.
///   `AVSpeechSynthesizer` does not start speaking synchronously,
///   so there is a window where an utterance is queued but `isSpeaking` is still `false`.
/// - Any delegate installed on the wrapped synthesizer beforehand is captured
///   and kept informed via ``forwardingDelegate``,
///   so wrapping an existing synthesizer does not break the host application's own callbacks.
///
/// ```swift
/// let synthesizer = QueueTrackingSpeechSynthesizer()
/// let observer = SpokenInstructionObserver(synthesizer: synthesizer, isMuted: false)
/// ```
public final class QueueTrackingSpeechSynthesizer: NSObject, QueueObservableSpeechSynthesizer {
    private struct State {
        /// Utterances enqueued through ``speak(_:)`` that have not yet finished or cancelled.
        var outstandingUtterances = 0
        var onUtteranceQueueDrained: (@Sendable () -> Void)?
        /// Weak, so that wrapping never extends the lifetime of the host application's delegate.
        weak var forwardingDelegate: AVSpeechSynthesizerDelegate?
    }

    /// `AVSpeechSynthesizer` is safe to message from any thread and this reference is never
    /// reassigned after `init`, but the type carries no `Sendable` annotation of its own.
    private nonisolated(unsafe) let synthesizer: AVSpeechSynthesizer

    /// Guards ``State``.
    ///
    /// The three access paths genuinely run concurrently:
    /// ``speak(_:)`` is called from the observer's tasks,
    /// the `AVSpeechSynthesizerDelegate` callbacks arrive on AVFoundation's own queue,
    /// and ``isSpeaking`` is read by the observer's fallback poll.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A delegate that receives every `AVSpeechSynthesizerDelegate` callback
    /// after this wrapper has updated its own bookkeeping.
    ///
    /// Initialised to whatever delegate the wrapped synthesizer already had,
    /// so wrapping a synthesizer the host application was already using is non-destructive.
    /// Held weakly, mirroring `AVSpeechSynthesizer.delegate`.
    public var forwardingDelegate: AVSpeechSynthesizerDelegate? {
        get { state.withLock { $0.forwardingDelegate } }
        set { state.withLock { $0.forwardingDelegate = newValue } }
    }

    /// Wraps an `AVSpeechSynthesizer`, taking over its `delegate` slot.
    ///
    /// - Parameter synthesizer: The synthesizer to wrap.
    ///   Any delegate it already has is preserved as ``forwardingDelegate``.
    public init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()

        // Capture before overwriting; order matters.
        forwardingDelegate = synthesizer.delegate
        synthesizer.delegate = self
    }

    deinit {
        // `AVSpeechSynthesizer.delegate` is weak, so it would simply go nil here. Hand the slot
        // back instead: the wrapped synthesizer is frequently owned by the host application and
        // outlives us, and it should not lose its own callbacks because navigation ended. The
        // identity check avoids clobbering a delegate somebody else installed in the meantime.
        if synthesizer.delegate === self {
            synthesizer.delegate = state.withLock { $0.forwardingDelegate }
        }
    }

    public var onUtteranceQueueDrained: (@Sendable () -> Void)? {
        get { state.withLock { $0.onUtteranceQueueDrained } }
        set { state.withLock { $0.onUtteranceQueueDrained = newValue } }
    }

    public var isSpeaking: Bool {
        // The second term is a safety net for utterances enqueued directly on the wrapped
        // synthesizer, bypassing this wrapper. Our count would miss those, but reporting
        // "not speaking" while audio is playing is exactly the mistake that wedges the session.
        state.withLock { $0.outstandingUtterances > 0 } || synthesizer.isSpeaking
    }

    public func speak(_ utterance: AVSpeechUtterance) {
        state.withLock { $0.outstandingUtterances += 1 }
        synthesizer.speak(utterance)
    }

    @discardableResult
    public func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        // `stopSpeaking(at:)` cancels every queued utterance, but utterances that never began
        // synthesis do not reliably deliver `didCancel`. Without this reset the count could
        // stay above zero forever, pinning other apps' audio in a ducked state indefinitely.
        // Late `didCancel` callbacks for those utterances are absorbed by the clamp in
        // `drainOne()`.
        let hadOutstandingUtterances = state.withLock { state -> Bool in
            let hadOutstandingUtterances = state.outstandingUtterances > 0
            state.outstandingUtterances = 0
            return hadOutstandingUtterances
        }

        let didStop = synthesizer.stopSpeaking(at: boundary)

        // Only `.immediate` silences the synthesizer synchronously. At a `.word` boundary the
        // current utterance is still being spoken, so announcing a drain here would invite the
        // observer to deactivate the session underneath it — the precise failure this type
        // exists to prevent. That case is left to the observer's fallback poll, which waits for
        // `isSpeaking` (whose second term above is still `true`) to go false on its own.
        if hadOutstandingUtterances, boundary == .immediate {
            notifyQueueDrained()
        }

        return didStop
    }

    private func drainOne() {
        let didDrain = state.withLock { state -> Bool in
            // Clamp rather than decrement blindly: a late `didCancel` can arrive after
            // `stopSpeaking(at:)` has already reset the count. Letting it go negative would
            // make the *next* utterance read as idle, releasing focus while it speaks.
            guard state.outstandingUtterances > 0 else { return false }
            state.outstandingUtterances -= 1
            return state.outstandingUtterances == 0
        }

        if didDrain {
            notifyQueueDrained()
        }
    }

    private func notifyQueueDrained() {
        // Read under the lock, invoke outside it: the handler calls back into the observer,
        // which takes its own lock.
        let handler = state.withLock { $0.onUtteranceQueueDrained }
        handler?()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

/// Every callback updates this wrapper's bookkeeping first,
/// then forwards to ``QueueTrackingSpeechSynthesizer/forwardingDelegate`` unchanged.
/// The `AVSpeechSynthesizer` passed along is the wrapped instance, not this wrapper,
/// which is what a delegate installed before wrapping expects to receive.
extension QueueTrackingSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        drainOne()
        forwardingDelegate?.speechSynthesizer?(synthesizer, didFinish: utterance)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        drainOne()
        forwardingDelegate?.speechSynthesizer?(synthesizer, didCancel: utterance)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        forwardingDelegate?.speechSynthesizer?(synthesizer, didStart: utterance)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        forwardingDelegate?.speechSynthesizer?(synthesizer, didPause: utterance)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        forwardingDelegate?.speechSynthesizer?(synthesizer, didContinue: utterance)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        forwardingDelegate?.speechSynthesizer?(
            synthesizer,
            willSpeakRangeOfSpeechString: characterRange,
            utterance: utterance
        )
    }

    @available(iOS 17.0, *)
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeak marker: AVSpeechSynthesisMarker,
        utterance: AVSpeechUtterance
    ) {
        forwardingDelegate?.speechSynthesizer?(synthesizer, willSpeak: marker, utterance: utterance)
    }
}

/// - Warning: This conformance cannot track the utterance queue,
/// because `AVSpeechSynthesizer` exposes exactly one `delegate` slot
/// and a library has no safe way to claim it from a synthesizer it does not own.
/// ``SpokenInstructionObserver`` therefore falls back to polling ``SpeechSynthesizer/isSpeaking``
/// for such a synthesizer, which can release audio focus in the gap between chained utterances.
/// Prefer ``QueueTrackingSpeechSynthesizer``, which wraps an `AVSpeechSynthesizer`
/// and preserves any delegate it already had.
extension AVSpeechSynthesizer: SpeechSynthesizer {
    // No def required
}

class PreviewSpeechSynthesizer: SpeechSynthesizer {
    var isSpeaking: Bool = false

    func speak(_: AVSpeechUtterance) {
        // No action for previews
    }

    func stopSpeaking(at _: AVSpeechBoundary) -> Bool {
        // No action for previews
        true
    }
}
