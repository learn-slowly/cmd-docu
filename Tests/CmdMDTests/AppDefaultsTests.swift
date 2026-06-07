import AppKit
import XCTest
@testable import CmdMD

final class AppDefaultsTests: XCTestCase {
    func testAppStartsInPreviewOnlyReviewMode() {
        let defaults = AppLaunchDefaults()

        XCTAssertEqual(defaults.viewMode, .preview)
        XCTAssertFalse(defaults.sidebarVisible)
    }

    func testAppLaunchDefaultsUseRegularActivationPolicyForPackagedWindowLaunch() {
        let defaults = AppLaunchDefaults()

        XCTAssertEqual(
            defaults.activationPolicy,
            NSApplication.ActivationPolicy.regular,
            "Packaged CmdMD.app must launch as a regular Dock app so Finder/open presents a main window."
        )
        XCTAssertTrue(
            defaults.activatesOnLaunch,
            "Packaged CmdMD.app should activate during launch so its main window is brought forward."
        )
        XCTAssertTrue(
            defaults.requiresRegularLaunchActivation,
            "Packaged CmdMD.app should require regular activation during launch so open -a presents a foreground window."
        )
    }
}
