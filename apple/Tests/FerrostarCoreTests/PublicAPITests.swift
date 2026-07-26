// NOTE: This file deliberately uses a plain `import`, *not* `@testable import`.
//
// `@testable` makes internal declarations visible, so a test written that way passes whether a
// symbol is `public` or `internal` and therefore cannot detect a visibility regression. Everything
// asserted here is asserted from the position of a host application consuming the package.
import FerrostarCore
import FerrostarCoreFFI
import XCTest

final class PublicAPITests: XCTestCase {
    /// Host applications need to hand the same navigation configuration to other FFI entry points.
    /// Without this being public they have to hand-assemble a second
    /// `FerrostarCoreFFI.NavigationControllerConfig`, and nothing then enforces that the two
    /// literals agree — a mismatch surfaces as navigation behaving differently depending on which
    /// path built the config.
    func test_swiftNavigationControllerConfig_exposesItsFFIValue() {
        let config = SwiftNavigationControllerConfig(
            waypointAdvance: .waypointWithinRange(100.0),
            stepAdvanceCondition: stepAdvanceDistanceToEndOfStep(
                distance: 10,
                minimumHorizontalAccuracy: 32
            ),
            arrivalStepAdvanceCondition: stepAdvanceDistanceToEndOfStep(
                distance: 5,
                minimumHorizontalAccuracy: 32
            ),
            routeDeviationTracking: .none,
            snappedLocationCourseFiltering: .snapToRoute
        )

        // Reading this from outside the module is the whole point; it fails to compile if the
        // property reverts to internal.
        let ffiValue: FerrostarCoreFFI.NavigationControllerConfig = config.ffiValue

        XCTAssertEqual(ffiValue.waypointAdvance, .waypointWithinRange(100.0))
        XCTAssertEqual(ffiValue.snappedLocationCourseFiltering, .snapToRoute)
    }
}
