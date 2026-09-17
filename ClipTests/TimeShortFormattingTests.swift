import XCTest
@testable import Clip

/// `timeShort` is the compact age label on every card in the grid - "now",
/// "3m", "2h", "5d". Each bucket boundary gets one test on each side, because
/// an off-by-one here silently mislabels every item near a boundary forever.
final class TimeShortFormattingTests: XCTestCase {

    private func item(agedBy seconds: TimeInterval) -> ClipboardItem {
        ClipboardItem(kind: .text, text: "x", timestamp: Date().addingTimeInterval(-seconds))
    }

    func test_underAMinute_isNow() {
        XCTAssertEqual(item(agedBy: 0).timeShort, "now")
        XCTAssertEqual(item(agedBy: 59).timeShort, "now")
    }

    func test_atOneMinute_switchesToMinutes() {
        XCTAssertEqual(item(agedBy: 60).timeShort, "1m")
        XCTAssertEqual(item(agedBy: 125).timeShort, "2m")
    }

    func test_justUnderAnHour_isStillMinutes() {
        XCTAssertEqual(item(agedBy: 3599).timeShort, "59m")
    }

    func test_atOneHour_switchesToHours() {
        XCTAssertEqual(item(agedBy: 3600).timeShort, "1h")
        XCTAssertEqual(item(agedBy: 7260).timeShort, "2h")
    }

    func test_justUnderADay_isStillHours() {
        XCTAssertEqual(item(agedBy: 86399).timeShort, "23h")
    }

    func test_atOneDay_switchesToDays() {
        XCTAssertEqual(item(agedBy: 86400).timeShort, "1d")
        XCTAssertEqual(item(agedBy: 86400 * 5).timeShort, "5d")
    }
}
