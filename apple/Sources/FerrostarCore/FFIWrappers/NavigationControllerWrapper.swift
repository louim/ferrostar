import CoreLocation
import FerrostarCoreFFI
import Foundation

/// A Swift wrapper around `UniFFI.NavigationControllerConfig`.
public struct SwiftNavigationControllerConfig {
    public init(waypointAdvance: WaypointAdvanceMode,
                stepAdvanceCondition: StepAdvanceCondition,
                arrivalStepAdvanceCondition: StepAdvanceCondition,
                routeDeviationTracking: SwiftRouteDeviationTracking,
                snappedLocationCourseFiltering: CourseFiltering)
    {
        ffiValue = FerrostarCoreFFI.NavigationControllerConfig(
            waypointAdvance: waypointAdvance,
            stepAdvanceCondition: stepAdvanceCondition,
            arrivalStepAdvanceCondition: arrivalStepAdvanceCondition,
            routeDeviationTracking: routeDeviationTracking.ffiValue,
            snappedLocationCourseFiltering: snappedLocationCourseFiltering
        )
    }

    /// The underlying FFI configuration.
    ///
    /// Exposed so that host applications can hand the same configuration to other FFI entry
    /// points without rebuilding it by hand. Keeping a second, hand-assembled
    /// `NavigationControllerConfig` in sync with this one is a silent drift hazard: nothing
    /// enforces that the two literals agree, and a mismatch shows up as navigation behaving
    /// differently depending on which path constructed the config.
    ///
    /// Read-only, so that the typed initialiser above remains the only way to build one.
    public private(set) var ffiValue: FerrostarCoreFFI.NavigationControllerConfig
}
