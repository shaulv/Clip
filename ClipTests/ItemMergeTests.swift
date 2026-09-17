import XCTest
@testable import Clip

/// `ItemMerge.identity`/`combine` decide whether two clips are "the same
/// item" and, when they are, which side's fields survive. Two real bugs
/// lived here before this suite existed: S1 folded a deliberate duplicate
/// into its source because an unchanged edit still matched on payload, and
/// S4 lost a pin because `combine` was not picking the most-configured
/// value for every field. These tests pin down identity and the combine
/// survivor rule directly, with no I/O and no `HistoryStore`, mirroring
/// qa-probe.py sections 150a (duplicate survives), 150b (remove-duplicates
/// fold), and 150e (a fold carries the pin to the survivor).
final class ItemMergeTests: XCTestCase {

    private func makeItem(
        text: String? = "hello world",
        kind: ItemKind = .text,
        title: String? = nil,
        tags: [String] = [],
        isPinned: Bool = false,
        pinnedIndex: Int = 0,
        shortcut: String? = nil,
        timestamp: Date = Date(),
        updatedAt: Date = Date(),
        hexColor: String? = nil,
        imageFile: String? = nil,
        filePaths: [String] = []
    ) -> ClipboardItem {
        ClipboardItem(
            kind: kind,
            text: text,
            imageFile: imageFile,
            filePaths: filePaths,
            hexColor: hexColor,
            timestamp: timestamp,
            isPinned: isPinned,
            pinnedIndex: pinnedIndex,
            title: title,
            tags: tags,
            shortcut: shortcut,
            updatedAt: updatedAt
        )
    }

    // MARK: identity

    func test_identity_sameContentDifferentMetadata_isTheSame() {
        // A pin, a tag, a shortcut - none of that is what the item IS.
        let a = makeItem(text: "same text", isPinned: true, pinnedIndex: 3)
        let b = makeItem(text: "same text", tags: ["x"], isPinned: false, shortcut: "Control+1")
        XCTAssertEqual(ItemMerge.identity(a), ItemMerge.identity(b))
    }

    func test_identity_differentContent_isDifferent() {
        let a = makeItem(text: "alpha")
        let b = makeItem(text: "bravo")
        XCTAssertNotEqual(ItemMerge.identity(a), ItemMerge.identity(b))
    }

    func test_identity_whitespaceAndCaseAreNotIgnored() {
        // The identity trims surrounding whitespace but does not fold case or
        // internal whitespace - "Hello" and "hello" are different bodies.
        let a = makeItem(text: "  Hello World  ")
        let b = makeItem(text: "Hello World")
        let c = makeItem(text: "hello world")
        XCTAssertEqual(ItemMerge.identity(a), ItemMerge.identity(b),
                        "surrounding whitespace is trimmed")
        XCTAssertNotEqual(ItemMerge.identity(b), ItemMerge.identity(c),
                           "case is part of the payload")
    }

    func test_identity_differsAcrossKinds() {
        // Same visible characters, different kind, are not the same item.
        let text = makeItem(text: "#112233", kind: .text)
        let color = makeItem(text: nil, kind: .color, hexColor: "#112233")
        XCTAssertNotEqual(ItemMerge.identity(text), ItemMerge.identity(color))
    }

    func test_identity_imageKind_usesFilenameAndPaths() {
        let a = makeItem(text: nil, kind: .image, imageFile: "a.png")
        let b = makeItem(text: nil, kind: .image, imageFile: "b.png")
        XCTAssertNotEqual(ItemMerge.identity(a), ItemMerge.identity(b),
                           "different backing files are different items")
    }

    func test_identity_namedDuplicateDiffersFromItsSource() {
        // This is the shape "duplicate" relies on: renaming the copy is what
        // makes it a distinct identity, per the doc comment on `identity`.
        let source = makeItem(text: "body", title: nil)
        let copy = makeItem(text: "body", title: "body copy")
        XCTAssertNotEqual(ItemMerge.identity(source), ItemMerge.identity(copy))
    }

    // MARK: combine - most-configured-copy-wins

    func test_combine_pin_survivesFromEitherSide() {
        let older = makeItem(isPinned: true, timestamp: Date(timeIntervalSince1970: 100))
        let newer = makeItem(isPinned: false, timestamp: Date(timeIntervalSince1970: 200))
        let out = ItemMerge.combine(older, newer)
        XCTAssertTrue(out.isPinned, "a pin on either side must survive the fold")
    }

    func test_combine_tags_arePooledFromBothSides() {
        let a = makeItem(tags: ["work", "urgent"])
        let b = makeItem(tags: ["urgent", "home"])
        let out = ItemMerge.combine(a, b)
        XCTAssertEqual(Set(out.tags), Set(["work", "urgent", "home"]))
    }

    func test_combine_title_prefersMostRecentlyUpdatedNonEmptyValue() {
        let stale = makeItem(title: "Old Title", updatedAt: Date(timeIntervalSince1970: 100))
        let recent = makeItem(title: "New Title", updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ItemMerge.combine(stale, recent).title, "New Title")
        // Order-independence: swapping the arguments must not change the answer.
        XCTAssertEqual(ItemMerge.combine(recent, stale).title, "New Title")
    }

    func test_combine_title_emptySideDoesNotOverwriteTheOther() {
        // The recent side has no title at all; the stale side's must fill the gap.
        let stale = makeItem(title: "Keep Me", updatedAt: Date(timeIntervalSince1970: 100))
        let recent = makeItem(title: nil, updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ItemMerge.combine(stale, recent).title, "Keep Me")
    }

    func test_combine_shortcut_prefersMostRecentlyUpdatedValue() {
        let stale = makeItem(shortcut: "Control+Option+1", updatedAt: Date(timeIntervalSince1970: 100))
        let recent = makeItem(shortcut: "Control+Option+2", updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ItemMerge.combine(stale, recent).shortcut, "Control+Option+2")
    }

    func test_combine_notes_textFollowsTheClockNotLength() {
        // A shorter, more recent edit must win over a longer, older body -
        // otherwise editing a note down to a shorter sentence appears to
        // work and the next fold silently undoes it.
        let stale = makeItem(text: "a much longer older paragraph of text",
                              updatedAt: Date(timeIntervalSince1970: 100))
        let recent = makeItem(text: "short edit", updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ItemMerge.combine(stale, recent).text, "short edit")
    }

    func test_combine_updatedAt_isTheMaxOfBothSides() {
        let a = makeItem(updatedAt: Date(timeIntervalSince1970: 100))
        let b = makeItem(updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ItemMerge.combine(a, b).updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ItemMerge.combine(b, a).updatedAt, Date(timeIntervalSince1970: 200))
    }

    func test_combine_isOrderIndependent() {
        // combine(a, b) and combine(b, a) must agree on every field, or two
        // Macs applying the same fold in a different order settle differently
        // forever.
        let a = makeItem(text: "x", title: "A", tags: ["a"], isPinned: true,
                          timestamp: Date(timeIntervalSince1970: 50),
                          updatedAt: Date(timeIntervalSince1970: 150))
        let b = makeItem(text: "y", title: "B", tags: ["b"], isPinned: false,
                          timestamp: Date(timeIntervalSince1970: 60),
                          updatedAt: Date(timeIntervalSince1970: 140))
        var ab = ItemMerge.combine(a, b)
        var ba = ItemMerge.combine(b, a)
        // ids are per-call identity, not a combine output worth comparing here.
        ab.id = a.id
        ba.id = a.id
        XCTAssertEqual(ab, ba)
    }

    // MARK: S1 - an unchanged Duplicate must not fold into its source

    func test_S1_unchangedDuplicateDoesNotFoldIntoItsSource() {
        // "Duplicate" names the copy, which is exactly what keeps its
        // identity apart from the source per the doc comment. A merge run
        // over both, with the copy untouched, must keep two rows.
        let source = makeItem(text: "same body", title: nil)
        let duplicate = makeItem(text: "same body", title: "same body copy")
        let result = ItemMerge.merge([duplicate], into: [source])
        XCTAssertEqual(result.items.count, 2, "the duplicate must survive the merge untouched")
        XCTAssertTrue(result.absorbed.isEmpty, "nothing should have been folded away")
    }

    // MARK: S4 - a pin lost then restored

    func test_S4_pinSurvivesAFoldEvenWhenTheNewerSideDroppedIt() {
        // The regression shape: the newer record (which wins every other
        // field) is not pinned, but the older one was. The pin must not be
        // lost just because the newer side "wins".
        let olderPinned = makeItem(isPinned: true, pinnedIndex: 2,
                                    timestamp: Date(timeIntervalSince1970: 10),
                                    updatedAt: Date(timeIntervalSince1970: 10))
        let newerUnpinned = makeItem(isPinned: false,
                                      timestamp: Date(timeIntervalSince1970: 20),
                                      updatedAt: Date(timeIntervalSince1970: 20))
        let result = ItemMerge.merge([newerUnpinned], into: [olderPinned])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.items[0].isPinned, "the pin must move to the survivor, not vanish")
    }

    // MARK: tombstones - fold interaction

    func test_fold_reportsTheLosingIdAsAbsorbed() {
        // The caller needs the absorbed id to push a tombstone; without it
        // the server keeps handing the duplicate back forever.
        let existing = makeItem(text: "dup", timestamp: Date(timeIntervalSince1970: 10))
        let incoming = makeItem(text: "dup", timestamp: Date(timeIntervalSince1970: 20))
        let result = ItemMerge.merge([incoming], into: [existing])
        XCTAssertEqual(result.items.count, 1)
        // The older id (by `timestamp`) survives; the newer one is absorbed.
        XCTAssertEqual(result.absorbed, [incoming.id])
        XCTAssertFalse(result.absorbed.contains(existing.id))
    }

    func test_fold_survivorIsNeverAlsoReportedAsAbsorbed() {
        // A survivor that is also reported absorbed would tell the server to
        // delete the very row that is supposed to exist.
        let existing = makeItem(text: "dup", timestamp: Date(timeIntervalSince1970: 10))
        let incoming = makeItem(text: "dup", timestamp: Date(timeIntervalSince1970: 20))
        let result = ItemMerge.merge([incoming], into: [existing])
        let survivors = Set(result.items.map(\.id))
        for id in result.absorbed {
            XCTAssertFalse(survivors.contains(id))
        }
    }

    // MARK: sync-replay symmetry

    func test_syncReplaySymmetry_localInsertAndRemoteReplayReachTheSameSurvivor() {
        // A local edit that folds two rows, replayed later as if it arrived
        // from sync (same two records, same order-independent merge), must
        // settle on the same surviving id and the same fields - otherwise
        // the two Macs disagree about which row is "the" row.
        let recordA = makeItem(text: "shared body", title: "shared body",
                                isPinned: true,
                                timestamp: Date(timeIntervalSince1970: 30),
                                updatedAt: Date(timeIntervalSince1970: 30))
        let recordB = makeItem(text: "shared body", title: "shared body",
                                tags: ["synced"],
                                timestamp: Date(timeIntervalSince1970: 40),
                                updatedAt: Date(timeIntervalSince1970: 40))

        // Local: A already on disk, B arrives as a local edit/insert.
        let local = ItemMerge.merge([recordB], into: [recordA])

        // Remote replay: the server hands back the same two records in the
        // other order, as a fresh sync merge would see them.
        let replay = ItemMerge.merge([recordA], into: [recordB])

        XCTAssertEqual(local.items.count, 1)
        XCTAssertEqual(replay.items.count, 1)
        XCTAssertEqual(local.items[0].id, replay.items[0].id,
                        "local insert and remote replay must agree on the survivor's id")
        XCTAssertEqual(local.items[0].isPinned, replay.items[0].isPinned)
        XCTAssertEqual(Set(local.items[0].tags), Set(replay.items[0].tags))
        XCTAssertEqual(local.items[0].title, replay.items[0].title)
    }
}
