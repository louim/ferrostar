import ActivityKit

/// A live activity that has already been requested.
///
/// ``FerrostarWidgetProvider`` talks to activities through this rather than to `Activity` directly,
/// so that its lifecycle — which is where the interesting bugs live — can be tested.
/// A real `Activity` cannot be created in a unit test:
/// requesting one needs live activity support and entitlements the test host does not have.
@available(iOS 16.2, *)
protocol LiveActivitySession: AnyObject {
    func update(_ content: ActivityContent<TripActivityAttributes.ContentState>) async
    func end(dismissalPolicy: ActivityUIDismissalPolicy) async
}

/// Requests live activities, and reports the ones already running.
@available(iOS 16.2, *)
protocol LiveActivityRequesting: Sendable {
    /// Activities for our attributes type that are already running.
    ///
    /// After a force quit these outlive the process that started them,
    /// which is why the provider has to look.
    var activeSessions: [any LiveActivitySession] { get }

    func request(
        content: ActivityContent<TripActivityAttributes.ContentState>
    ) throws -> any LiveActivitySession
}

@available(iOS 16.2, *)
extension Activity: LiveActivitySession where Attributes == TripActivityAttributes {
    // `update(_:)` is satisfied by ActivityKit's own method of the same name; redeclaring it here
    // would shadow the SDK's.

    func end(dismissalPolicy: ActivityUIDismissalPolicy) async {
        await end(nil, dismissalPolicy: dismissalPolicy)
    }
}

/// The real ActivityKit-backed implementation.
@available(iOS 16.2, *)
struct ActivityKitRequester: LiveActivityRequesting {
    var activeSessions: [any LiveActivitySession] {
        Activity<TripActivityAttributes>.activities
    }

    func request(
        content: ActivityContent<TripActivityAttributes.ContentState>
    ) throws -> any LiveActivitySession {
        try Activity.request(attributes: TripActivityAttributes(), content: content)
    }
}
