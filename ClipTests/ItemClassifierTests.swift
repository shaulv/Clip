import XCTest
@testable import Clip

/// The one place that decides what a piece of text *is*. The ladder's ORDER
/// is the behaviour worth protecting - a curated role beats a color, a color
/// beats code, and a preferred tab never overrides a document Clip actually
/// recognised.
final class ItemClassifierTests: XCTestCase {

    // MARK: firstLineTitle

    func test_firstLineTitle_usesFirstNonEmptyLine() {
        let text = "\n\n  Hello World  \nsecond line"
        XCTAssertEqual(ItemClassifier.firstLineTitle(text), "Hello World")
    }

    func test_firstLineTitle_skipsFrontMatterFence() {
        let text = "---\ntitle: nope\n---\nReal Title\nbody"
        // The lone "---" line is skipped; the next non-empty line wins.
        XCTAssertEqual(ItemClassifier.firstLineTitle(text), "title: nope")
    }

    func test_firstLineTitle_stripsLeadingMarkdownHeadingHashes() {
        XCTAssertEqual(ItemClassifier.firstLineTitle("## A Heading\nbody"), "A Heading")
    }

    func test_firstLineTitle_truncatesLongLinesWithEllipsis() {
        let long = String(repeating: "x", count: 100)
        let title = ItemClassifier.firstLineTitle(long)
        XCTAssertEqual(title.count, 58) // 57 chars + the ellipsis character
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func test_firstLineTitle_allBlank_returnsUntitled() {
        XCTAssertEqual(ItemClassifier.firstLineTitle("\n\n   \n---\n"), "Untitled")
    }

    // MARK: item(fromText:) ladder order

    func test_plainProse_becomesPlainText() {
        let item = ItemClassifier.item(fromText: "just an ordinary sentence about nothing in particular")
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.role, .clip)
    }

    func test_hexColor_isRecognisedRegardlessOfSource() {
        // The doc comment on this path is explicit: a color is a color
        // however it arrived, even with no preferred tab at all.
        let item = ItemClassifier.item(fromText: "#3CFFD0")
        XCTAssertEqual(item.kind, .color)
        XCTAssertEqual(item.hexColor, "#3CFFD0")
    }

    func test_preferredCuratedTab_winsOverABareHexColor() {
        // The ladder checks curatedRole, THEN preferredRole.isCurated, and
        // only THEN the color/code fallbacks - so a drop into a curated tab
        // (Notes, in this case a curated .note) claims the text as a note
        // of kind .text before the bare-hex check ever runs. This is the
        // order the ladder actually uses, worth pinning down precisely
        // because it is easy to assume color is checked first.
        let item = ItemClassifier.item(fromText: "#112233", preferredRole: .note)
        XCTAssertEqual(item.role, .note)
        XCTAssertEqual(item.kind, .text)
    }

    func test_bareHexWithNoPreferredRole_becomesAColor() {
        let item = ItemClassifier.item(fromText: "#112233")
        XCTAssertEqual(item.kind, .color)
    }

    func test_preferredCuratedRole_appliesWhenNotAColorAndNotDetected() {
        let item = ItemClassifier.item(fromText: "a short plain note with no structure",
                                       preferredRole: .note)
        XCTAssertEqual(item.role, .note)
        XCTAssertEqual(item.kind, .text)
    }

    func test_preferredNonCuratedRole_isIgnored_clipStaysClip() {
        // .clip is not curated (`isCurated` is false for it), so passing it
        // explicitly must behave exactly like passing nil.
        let item = ItemClassifier.item(fromText: "plain text here", preferredRole: .clip)
        XCTAssertEqual(item.role, .clip)
    }

    func test_title_override_winsOverDerivedTitle() {
        let item = ItemClassifier.item(fromText: "some body text", preferredRole: .note,
                                       title: "My Chosen Title")
        XCTAssertEqual(item.title, "My Chosen Title")
    }

    func test_sourceAppMetadata_isCarriedThrough() {
        let item = ItemClassifier.item(fromText: "hello", sourceApp: "com.apple.Notes",
                                       sourceAppName: "Notes")
        XCTAssertEqual(item.sourceApp, "com.apple.Notes")
        XCTAssertEqual(item.sourceAppName, "Notes")
    }
}
