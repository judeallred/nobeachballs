import AppKit
import SwiftUI
import XCTest
@testable import NoBeachballs

final class DashboardTests: XCTestCase {
    func testDashboardIsLazyReleasedAndPreservesUserChoices() async {
        await MainActor.run {
            _ = NSApplication.shared
            let monitor = Monitor(controlsProcesses: false)
            let status = StatusItemController(monitor: monitor)
            XCTAssertNil(status.dashboardController)
            weak var oldController: NSViewController?

            autoreleasepool {
                status.prepareDashboard()
                let controller = status.dashboardController as! NSHostingController<MonitorView>
                oldController = controller
                XCTAssertTrue(monitor.isVisible)
                let choices = controller.rootView.listState
                choices.query = "beach"
                choices.mode = .all
                choices.sort = .memory
                choices.showSystem = true
                choices.expanded = ["job:example"]
                // Exercise hosting, rather than checking only an uninitialized controller.
                controller.view.frame = NSRect(x: 0, y: 0, width: 940, height: 760)
                controller.view.layoutSubtreeIfNeeded()
                status.discardDashboard()
            }
            XCTAssertNil(status.dashboardController)
            XCTAssertNil(oldController, "Closing must release the hosting controller")
            XCTAssertFalse(monitor.isVisible)
            XCTAssertTrue(monitor.groups.isEmpty)

            status.prepareDashboard()
            let reopened = status.dashboardController as! NSHostingController<MonitorView>
            let choices = reopened.rootView.listState
            XCTAssertEqual(choices.query, "beach")
            XCTAssertEqual(choices.mode, .all)
            XCTAssertEqual(choices.sort, .memory)
            XCTAssertTrue(choices.showSystem)
            XCTAssertEqual(choices.expanded, ["job:example"])
            status.discardDashboard()
        }
    }
}
