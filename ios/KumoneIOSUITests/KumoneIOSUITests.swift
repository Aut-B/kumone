import XCTest

final class KumoneIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchFieldIsVisibleFromLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-kumone.search.tab", "-kumone.ui.test"]
        app.launch()
        assertSearchFieldVisible(in: app)
    }

    @MainActor
    func testSearchTabShowsSearchField() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-kumone.ui.test"]
        app.launch()

        let searchTab = app.descendants(matching: .any)["kumone.tab.search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20), "Search tab did not appear")
        searchTab.tap()

        assertSearchFieldVisible(in: app)
    }

    @MainActor
    private func assertSearchFieldVisible(in app: XCUIApplication) {
        let searchField = app.textFields["kumone.search.field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 20), "Search field did not appear")

        let deadline = Date().addingTimeInterval(10)
        while !searchField.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(searchField.isHittable, "Search field is not hittable")
        XCTAssertGreaterThan(searchField.frame.width, 100, "Search field is too narrow")
        XCTAssertGreaterThan(searchField.frame.height, 20, "Search field is too short")
        XCTAssertLessThan(searchField.frame.minY, app.frame.height / 2, "Search field is outside the visible top half")
    }
}
