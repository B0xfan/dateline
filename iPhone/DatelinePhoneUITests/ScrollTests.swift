// Runs on GitHub in the simulator (scripts/ios-check.sh), on the sample calendars only: nothing is saved.
import XCTest

final class ScrollTests: XCTestCase {
    /// A swipe that starts on an event scrolls the day, the same as one that starts on an empty hour (John's video 2026-11-12).
    func testSwipeOnEventScrollsTheDay() {
        let app = XCUIApplication()
        app.launchArguments = ["--sample", "-demo", "day"]
        app.launch()
        let noon = app.staticTexts["Noon"]
        XCTAssertTrue(noon.waitForExistence(timeout: 10))
        sleep(1)  // the day centres on the current hour just after it opens
        guard let hours = app.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.height < $1.frame.height })?.frame else { return XCTFail("no scrolling hours on the day") }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        /// A quick 150 point swipe up from (x, y), as a thumb does; how far the hours moved. (A slow drag never scrolls in the simulator, even on an empty hour.)
        func swipeUp(x: CGFloat, y: CGFloat) -> CGFloat {
            XCTAssertTrue(hours.insetBy(dx: 0, dy: 10).contains(CGPoint(x: x, y: y)), "the swipe at \(x),\(y) starts outside the hours \(hours)")
            let before = noon.frame.minY
            let start = origin.withOffset(CGVector(dx: x, dy: y))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)), withVelocity: .fast, thenHoldForDuration: 0)
            sleep(1)
            return before - noon.frame.minY
        }
        let lunch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lunch with Sam'")).firstMatch
        XCTAssertTrue(lunch.waitForExistence(timeout: 5), "the sample lunch is not on the day")
        add(XCTAttachment(screenshot: app.screenshot()))  // the day as it opened
        // 1. Press and hold, then drag upwards (on the sample calendars: nothing is saved). Checked by where lunch is drawn, not by its wording.
        XCTAssertTrue(lunch.frame.minY > hours.minY + 130 && lunch.frame.maxY < hours.maxY - 10, "lunch \(lunch.frame) has no room above it in the hours \(hours)")
        let was = lunch.frame
        // shortcut: the bottom-edge resize is not checked here: holding it moved lunch's top by 9 points, the same with and without the swipe fix (2026-11-12); its own task.
        // Anywhere else on it: lunch moves up and keeps its length.
        let grip = origin.withOffset(CGVector(dx: was.midX, dy: was.minY + 10))
        grip.press(forDuration: 0.8, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: -100)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        let moved = lunch.frame
        XCTAssertLessThan(moved.minY, was.minY - 60, "press, hold and drag did not move lunch (\(was) to \(moved))")
        XCTAssertEqual(moved.height, was.height, accuracy: 3, "moving lunch changed its length (\(was) to \(moved))")
        // 2. Control: a swipe on the hour labels scrolls the day.
        let onLabels = swipeUp(x: 12, y: hours.midY)
        XCTAssertGreaterThan(onLabels, 60, "a swipe on the hour labels did not scroll the day (moved \(onLabels))")
        // 3. The bug: a swipe that starts on an event scrolls the day too. A fresh start puts lunch back low on the day.
        app.terminate(); app.launch()
        XCTAssertTrue(noon.waitForExistence(timeout: 10)); sleep(1)
        XCTAssertTrue(lunch.frame.minY > hours.minY + 10 && lunch.frame.minY < hours.maxY - 40, "lunch \(lunch.frame) is not inside the hours \(hours)")
        add(XCTAttachment(screenshot: app.screenshot()))  // where lunch was when the swipe started
        let onEvent = swipeUp(x: lunch.frame.midX, y: lunch.frame.minY + 15)
        XCTAssertGreaterThan(onEvent, 60, "a swipe starting on the lunch event did not scroll the day (moved \(onEvent))")
    }
}
