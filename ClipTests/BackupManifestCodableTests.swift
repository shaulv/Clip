import XCTest
@testable import Clip

/// A backup format has one obligation above every other: an archive written by
/// an older version of the app must still open. Swift's synthesised decoder
/// makes that easy to break by accident, because it ignores a property's
/// default value and throws on a missing key, so every field added to the
/// manifest silently invalidates every archive already on someone's disk. That
/// happened here once, when `droppedThemes` was added; these tests exist so it
/// cannot happen again quietly.
final class BackupManifestCodableTests: XCTestCase {

    /// A manifest exactly as versions before the dropped-content fields wrote
    /// it. No `droppedThemes`, no `droppedMedia`.
    private let olderManifest = """
        {
          "application": "Clip",
          "schemaVersion": 1,
          "createdAt": 768000000,
          "appVersion": "2.1 (21)",
          "includesSecrets": false,
          "counts": { "history": 3, "themes": 2 },
          "sections": ["history", "themes"]
        }
        """

    private func decode(_ json: String) throws -> BackupArchive.Manifest {
        try JSONDecoder.backup.decode(BackupArchive.Manifest.self, from: Data(json.utf8))
    }

    func test_manifestFromBeforeTheDropFields_stillDecodes() throws {
        let m = try decode(olderManifest)
        XCTAssertEqual(m.application, "Clip")
        XCTAssertEqual(m.schemaVersion, 1)
        XCTAssertEqual(m.count(.history), 3)
        XCTAssertTrue(m.has(.themes))
    }

    func test_manifestFromBeforeTheDropFields_reportsNothingDropped() throws {
        let m = try decode(olderManifest)
        XCTAssertEqual(m.droppedThemes, [])
        XCTAssertEqual(m.droppedMedia, [])
        XCTAssertNil(m.dropSummary, "an older archive must not claim it dropped anything")
    }

    /// The identity fields are the integrity gate: `restore` refuses an archive
    /// that is not Clip's, and refuses one from a newer schema. Defaulting
    /// either would let a foreign or truncated manifest look valid.
    func test_manifestMissingApplication_isRejected() {
        let json = #"{"schemaVersion":1,"counts":{},"sections":[]}"#
        XCTAssertThrowsError(try decode(json))
    }

    func test_manifestMissingSchemaVersion_isRejected() {
        let json = #"{"application":"Clip","counts":{},"sections":[]}"#
        XCTAssertThrowsError(try decode(json))
    }

    func test_roundTrip_preservesDroppedNames() throws {
        var written = BackupArchive.Manifest()
        written.droppedThemes = ["Nord copy"]
        written.droppedMedia = ["screenshot.png", "notes.rtf"]
        written.counts = ["history": 1]
        written.sections = ["history"]

        let data = try JSONEncoder.backup.encode(written)
        let read = try JSONDecoder.backup.decode(BackupArchive.Manifest.self, from: data)

        XCTAssertEqual(read.droppedThemes, ["Nord copy"])
        XCTAssertEqual(read.droppedMedia, ["screenshot.png", "notes.rtf"])
    }

    /// The wording is what a person acts on, so it is asserted rather than
    /// left to whatever the interpolation happens to produce.
    func test_dropSummary_namesOneThemeInTheSingular() {
        var m = BackupArchive.Manifest()
        m.droppedThemes = ["Nord copy"]
        XCTAssertEqual(m.dropSummary, "1 theme could not be included: Nord copy.")
    }

    func test_dropSummary_namesSeveralFilesInThePlural() {
        var m = BackupArchive.Manifest()
        m.droppedMedia = ["a.png", "b.png"]
        XCTAssertEqual(m.dropSummary, "2 files could not be included: a.png, b.png.")
    }

    func test_dropSummary_coversBothSectionsAtOnce() {
        var m = BackupArchive.Manifest()
        m.droppedThemes = ["Nord copy"]
        m.droppedMedia = ["a.png"]
        let summary = m.dropSummary ?? ""
        XCTAssertTrue(summary.contains("1 theme could not be included: Nord copy."), summary)
        XCTAssertTrue(summary.contains("1 file could not be included: a.png."), summary)
    }
}
