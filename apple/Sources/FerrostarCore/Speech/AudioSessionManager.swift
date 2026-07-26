import AVFoundation
import os

private let logger = Logger(subsystem: "com.stadiamaps.ferrostar", category: "AudioSessionManager")

/// A claim on audio focus, returned by ``AudioSessionControlling/acquireAudioFocus()``.
///
/// Opaque and unforgeable on purpose: releasing a hold that was never acquired,
/// or releasing the same hold twice,
/// is silently ignored rather than dropping somebody else's claim.
/// Navigation has several independent paths that may decide speech is over
/// — a completion callback, a poll, a watchdog, an explicit stop —
/// and any of them may fire for a claim that is already gone.
public struct AudioFocusHold: Hashable, Sendable {
    private let id: UUID

    /// Mints a fresh, unique hold.
    ///
    /// Public so that anything implementing ``AudioSessionControlling`` — a bridge to another
    /// audio stack, or a test double — can issue its own. A hold means nothing except to the
    /// ``AudioSessionControlling`` that created it, so minting one confers no claim by itself.
    public init() {
        id = UUID()
    }
}

/// Manages the process-wide `AVAudioSession` on behalf of everything that needs to be heard
/// during navigation.
///
/// ## Why this is a shared, counted resource
///
/// `AVAudioSession` is a singleton owned by the process, not by any one component.
/// If spoken guidance and (say) an arrival chime each activate and deactivate it on their own,
/// whichever finishes first calls `setActive(false)` while the other is still playing.
/// For speech that is not a cosmetic glitch:
/// the utterance is cut *without* a completion callback,
/// `AVSpeechSynthesizer.isSpeaking` then sticks at `true` indefinitely,
/// and all later guidance queues silently behind the dead utterance.
///
/// So focus is reference counted across *concurrent, unrelated* holders.
/// The holds do not nest — an arrival chime triggered from a step-completion callback
/// overlaps speech that is mid-queue, with no containment relationship —
/// so the rule is simply that the session is activated on the first hold
/// and deactivated only when the last one is released.
///
/// ## Usage
///
/// Prefer the scoped form, which cannot leak a hold:
///
/// ```swift
/// try await audioSession.withAudioFocus {
///     await chimePlayer.playToCompletion()
/// }
/// ```
///
/// Reach for ``acquireAudioFocus()`` / ``releaseAudioFocus(_:)`` only when the lifetime is
/// genuinely not scope-shaped, as it is for ``SpokenInstructionObserver``,
/// where the release is driven by a delegate callback rather than by returning from a function.
public protocol AudioSessionControlling: Sendable {
    /// Claims audio focus, activating the session if this is the first outstanding hold.
    func acquireAudioFocus() async -> AudioFocusHold

    /// Relinquishes a claim, deactivating the session if it was the last one outstanding.
    ///
    /// Releasing an unknown or already-released hold does nothing.
    func releaseAudioFocus(_ hold: AudioFocusHold) async
}

public extension AudioSessionControlling {
    /// Holds audio focus for the duration of `body`.
    ///
    /// The hold is released whether `body` returns or throws,
    /// which is why this should be preferred over the primitives wherever the shape allows it.
    func withAudioFocus<T>(_ body: () async throws -> T) async rethrows -> T {
        let hold = await acquireAudioFocus()

        do {
            let value = try await body()
            await releaseAudioFocus(hold)
            return value
        } catch {
            await releaseAudioFocus(hold)
            throw error
        }
    }
}

/// The subset of `AVAudioSession` this module drives.
///
/// Exists so that tests can assert the exact call sequence,
/// which is the only way to keep regressions like
/// [#608](https://github.com/stadiamaps/ferrostar/issues/608) (ducking) and
/// [#613](https://github.com/stadiamaps/ferrostar/issues/613) (`.voicePrompt`) from creeping back.
protocol AudioSessionHandle: Sendable {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionHandle {}

/// The default ``AudioSessionControlling``.
///
/// Because `AVAudioSession` is process-wide, so is the count that guards it:
/// use ``shared`` unless you are writing a test.
/// Two managers over one session would each keep their own count and defeat the purpose.
public actor AudioSessionManager: AudioSessionControlling {
    /// How the session is configured while Ferrostar holds focus.
    ///
    /// One configuration per manager, applied on every activation.
    /// Per-hold configuration is deliberately not offered:
    /// a second sound that reconfigured the session mid-utterance
    /// is one of the ways the wedge described on ``AudioSessionManager`` gets triggered.
    public struct Configuration: Sendable {
        public var category: AVAudioSession.Category
        public var mode: AVAudioSession.Mode
        public var options: AVAudioSession.CategoryOptions

        public init(
            category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            options: AVAudioSession.CategoryOptions
        ) {
            self.category = category
            self.mode = mode
            self.options = options
        }

        /// Ducks most other apps and interrupts spoken-word audio, at prompt volume.
        ///
        /// `.voicePrompt` is what keeps guidance audible over ducked music;
        /// `.interruptSpokenAudioAndMixWithOthers` is what pauses podcasts
        /// rather than talking over them.
        public static let navigationVoiceGuidance = Configuration(
            category: .playback,
            mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
    }

    /// The process-wide instance. Pass this to every component that needs to be heard.
    public static let shared = AudioSessionManager()

    private let session: AudioSessionHandle
    private let configuration: Configuration

    /// Outstanding holds. A set rather than a counter so that a double release,
    /// or a release of a hold from a previous trip, cannot silently decrement somebody else's.
    private var holds: Set<AudioFocusHold> = []

    public init(configuration: Configuration = .navigationVoiceGuidance) {
        self.init(configuration: configuration, session: AVAudioSession.sharedInstance())
    }

    init(configuration: Configuration = .navigationVoiceGuidance, session: AudioSessionHandle) {
        self.configuration = configuration
        self.session = session
    }

    /// Whether the session is currently active on our behalf.
    public var hasAudioFocus: Bool {
        !holds.isEmpty
    }

    public func acquireAudioFocus() -> AudioFocusHold {
        let hold = AudioFocusHold()
        let wasInactive = holds.isEmpty
        holds.insert(hold)

        if wasInactive {
            activate()
        }

        return hold
    }

    public func releaseAudioFocus(_ hold: AudioFocusHold) {
        // A no-op for an unknown hold, which is the point of the token: the observer has several
        // paths that can each conclude speech is finished, and only the first should count.
        guard holds.remove(hold) != nil else { return }

        if holds.isEmpty {
            deactivate()
        }
    }

    private func activate() {
        do {
            // Category, mode and options are set in a single call rather than separately. Setting
            // the category on its own momentarily drops the mode back to `.default`, and doing
            // that under a live utterance is one of the ways guidance gets cut mid-sentence.
            try session.setCategory(
                configuration.category,
                mode: configuration.mode,
                options: configuration.options
            )
            try session.setActive(true, options: [])
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    private func deactivate() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Failed to release audio session: \(error.localizedDescription)")
        }
    }

    deinit {
        if !holds.isEmpty {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
