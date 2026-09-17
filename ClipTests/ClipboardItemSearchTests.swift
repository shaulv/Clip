import XCTest
@testable import Clip

/// The three search modes a user can pick, and the one rule shared by all of
/// them: an empty query matches everything.
final class ClipboardItemSearchTests: XCTestCase {

    private func item(_ text: String) -> ClipboardItem {
        ClipboardItem(kind: .text, text: text)
    }

    // MARK: shared rule

    func test_emptyQuery_matchesEverything_inEveryMode() {
        let clip = item("anything at all")
        for mode in SearchMode.allCases {
            XCTAssertTrue(clip.matches("", mode: mode), "\(mode) should match an empty query")
        }
    }

    // MARK: exact (.literal contains)

    func test_exactMode_isCaseInsensitive() {
        let clip = item("The Quick Brown Fox")
        XCTAssertTrue(clip.matches("quick brown", mode: .exact))
    }

    func test_exactMode_requiresTheSubstringToActuallyAppear() {
        let clip = item("The Quick Brown Fox")
        XCTAssertFalse(clip.matches("slow turtle", mode: .exact))
    }

    // MARK: fuzzy (ordered subsequence)

    func test_fuzzyMode_matchesAnInOrderSubsequence() {
        let clip = item("clipboard manager")
        XCTAssertTrue(clip.matches("cbmgr", mode: .fuzzy))
    }

    func test_fuzzyMode_rejectsCharactersNotPresentAtAll() {
        let clip = item("clipboard manager")
        XCTAssertFalse(clip.matches("qxz", mode: .fuzzy))
    }


    func test_fuzzyMode_isCaseInsensitive() {
        let clip = item("ClipBoard")
        XCTAssertTrue(clip.matches("CB", mode: .fuzzy))
    }

    func test_fuzzyMode_rejectsAnOutOfOrderSubsequence() {
        // Uses the blob-taking overload directly so the fixed "clipboard
        // manager" text is not duplicated into the blob (searchBlob folds in
        // both previewText and fullText), which would otherwise let "r"
        // from the first copy pair with "c" from the second and hide the
        // very bug an ordering check exists to catch.
        let clip = item("clipboard manager")
        XCTAssertFalse(clip.matches("rc", mode: .fuzzy, blob: "clipboard manager"))
    }

    // MARK: regex

    func test_regexMode_matchesAPattern() {
        let clip = item("build 1234 succeeded")
        XCTAssertTrue(clip.matches("\\d{4}", mode: .regex))
    }

    func test_regexMode_isCaseInsensitiveByDesign() {
        let clip = item("HELLO world")
        XCTAssertTrue(clip.matches("hello", mode: .regex))
    }

    func test_regexMode_withInvalidPattern_failsClosed_ratherThanCrashing() {
        let clip = item("anything")
        XCTAssertFalse(clip.matches("(unterminated[", mode: .regex))
    }

    // MARK: what a query can reach

    func test_searchBlob_includesTitleAndSourceAppName_notJustTheBody() {
        var clip = item("body text")
        clip.title = "My Special Title"
        clip.sourceAppName = "Notes"
        XCTAssertTrue(clip.matches("special title", mode: .exact))
        XCTAssertTrue(clip.matches("notes", mode: .exact))
    }

    func test_searchBlob_includesTags() {
        var clip = item("body")
        clip.tags = ["urgent", "design-review"]
        XCTAssertTrue(clip.matches("urgent", mode: .exact))
    }
}
