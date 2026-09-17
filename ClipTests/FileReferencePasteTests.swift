import XCTest
@testable import Clip

/// Tests that primary-clicking or copying .file and .folder items places only their
/// filesystem path as plain text on the pasteboard, with no file URLs, attachments,
/// or directory payloads, while preserving kind classification, activation routing,
/// and video file reference pasting.
final class FileReferencePasteTests: XCTestCase {

    // MARK: - Path Resolver Tests

    func test_pathResolver_prefersFilePathsAndDeduplicatesInOrder() {
        let item = ClipboardItem(
            kind: .file,
            text: "/ignored/fallback.txt",
            filePaths: ["/first/path.txt", "/second/path.txt", "/first/path.txt", "   "]
        )

        let resolved = PathResolver.resolvePaths(for: item)
        XCTAssertEqual(resolved, ["/first/path.txt", "/second/path.txt"])
    }

    func test_pathResolver_legacyItem_withoutFilePaths_fallsBackToText() {
        let fileItem = ClipboardItem(
            kind: .file,
            text: "/legacy/path/file.txt",
            filePaths: []
        )
        XCTAssertEqual(PathResolver.resolvePaths(for: fileItem), ["/legacy/path/file.txt"])

        let folderItem = ClipboardItem(
            kind: .folder,
            text: "/legacy/path/folder",
            filePaths: []
        )
        XCTAssertEqual(PathResolver.resolvePaths(for: folderItem), ["/legacy/path/folder"])
    }

    func test_legacyFileFolderJSON_decodesAndResolvesPath() throws {
        // Simulates a legacy or imported record that has kind: file/folder and text, but no filePaths key
        let legacyJSON = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "kind": "file",
            "text": "/legacy/historic/doc.pdf",
            "timestamp": 0,
            "isPinned": false,
            "pinnedIndex": 0,
            "isFavorite": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        XCTAssertEqual(decoded.kind, .file)
        XCTAssertTrue(decoded.filePaths.isEmpty, "Legacy item should decode with empty filePaths array")
        XCTAssertEqual(decoded.text, "/legacy/historic/doc.pdf")

        let resolved = PathResolver.resolvePaths(for: decoded)
        XCTAssertEqual(resolved, ["/legacy/historic/doc.pdf"], "Resolver must recover live path from stored text")
    }

    func test_pathResolver_nonFileOrFolder_returnsEmpty() {
        let textItem = ClipboardItem(
            kind: .text,
            text: "/tmp/not-a-file-kind.txt",
            filePaths: ["/tmp/not-a-file-kind.txt"]
        )
        XCTAssertEqual(PathResolver.resolvePaths(for: textItem), [])

        let urlItem = ClipboardItem(
            kind: .url,
            text: "https://example.com",
            filePaths: ["/tmp/something"]
        )
        XCTAssertEqual(PathResolver.resolvePaths(for: urlItem), [])
    }

    // MARK: - Primary Activation Tests

    @MainActor
    func test_activatePrimary_historyList_requestsPaste() {
        let store = HistoryStore.shared
        store.pasteTicket = nil

        let fileItem = ClipboardItem(kind: .file, text: "/tmp/sample.txt", filePaths: ["/tmp/sample.txt"])
        store.addExisting(fileItem)

        let outcome = store.activatePrimary(fileItem, presentation: .historyList)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(store.selectedID, fileItem.id)
        XCTAssertEqual(store.pasteTicket?.item.id, fileItem.id)
    }

    @MainActor
    func test_activatePrimary_historyGallery_requestsPaste() {
        let store = HistoryStore.shared
        store.pasteTicket = nil

        let folderItem = ClipboardItem(kind: .folder, text: "/tmp/sample_dir", filePaths: ["/tmp/sample_dir"])
        store.addExisting(folderItem)

        let outcome = store.activatePrimary(folderItem, presentation: .historyGallery)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(store.selectedID, folderItem.id)
        XCTAssertEqual(store.pasteTicket?.item.id, folderItem.id)
    }

    @MainActor
    func test_activatePrimary_curatedGallery_requestsPaste() {
        let store = HistoryStore.shared
        store.pasteTicket = nil

        let item = ClipboardItem(kind: .text, text: "Curated item in gallery")
        store.addExisting(item)

        let outcome = store.activatePrimary(item, presentation: .curatedGallery)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(store.selectedID, item.id)
        XCTAssertEqual(store.pasteTicket?.item.id, item.id)
    }

    @MainActor
    func test_activatePrimary_curatedList_distinguishesFileFolderPromptFromDocuments() {
        let store = HistoryStore.shared

        // 1. File item pastes
        store.pasteTicket = nil
        store.isDetailOpen = false
        let fileItem = ClipboardItem(kind: .file, text: "/tmp/curated_file.txt", filePaths: ["/tmp/curated_file.txt"])
        store.addExisting(fileItem)
        let fileOutcome = store.activatePrimary(fileItem, presentation: .curatedList)
        XCTAssertEqual(fileOutcome, .pasted)
        XCTAssertEqual(store.pasteTicket?.item.id, fileItem.id)
        XCTAssertFalse(store.isDetailOpen)

        // 2. Folder item pastes
        store.pasteTicket = nil
        store.isDetailOpen = false
        let folderItem = ClipboardItem(kind: .folder, text: "/tmp/curated_dir", filePaths: ["/tmp/curated_dir"])
        store.addExisting(folderItem)
        let folderOutcome = store.activatePrimary(folderItem, presentation: .curatedList)
        XCTAssertEqual(folderOutcome, .pasted)
        XCTAssertEqual(store.pasteTicket?.item.id, folderItem.id)
        XCTAssertFalse(store.isDetailOpen)

        // 3. Prompt item pastes
        store.pasteTicket = nil
        store.isDetailOpen = false
        var promptItem = ClipboardItem(kind: .text, text: "A curated prompt without variables")
        promptItem.role = .prompt
        store.addExisting(promptItem)
        let promptOutcome = store.activatePrimary(promptItem, presentation: .curatedList)
        XCTAssertEqual(promptOutcome, .pasted)
        XCTAssertEqual(store.pasteTicket?.item.id, promptItem.id)
        XCTAssertFalse(store.isDetailOpen)

        // 4. Ordinary note / document opens detail
        store.pasteTicket = nil
        store.isDetailOpen = false
        var noteItem = ClipboardItem(kind: .text, text: "Meeting notes documentation")
        noteItem.role = .note
        store.addExisting(noteItem)
        let noteOutcome = store.activatePrimary(noteItem, presentation: .curatedList)
        XCTAssertEqual(noteOutcome, .openedDetail)
        XCTAssertNil(store.pasteTicket)
        XCTAssertTrue(store.isDetailOpen)
    }

    @MainActor
    func test_activatePrimary_promptWithVariables_returnsAwaitingVariables() {
        let store = HistoryStore.shared
        store.pasteTicket = nil
        store.fillingVariablesFor = nil

        var item = ClipboardItem(kind: .text, text: "Hello {{name}}, welcome to {{service}}!")
        item.role = .prompt
        store.addExisting(item)

        let outcome = store.activatePrimary(item, presentation: .curatedList)
        XCTAssertEqual(outcome, .awaitingVariables)
        XCTAssertNil(store.pasteTicket)
        XCTAssertEqual(store.fillingVariablesFor?.id, item.id)

        store.fillingVariablesFor = nil
    }

    // MARK: - ClipboardWriter Tests (Path Text Only)

    func test_clipboardWriter_liveFile_writesOnlyPathString_andNoFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fixtureFile = tempDir.appendingPathComponent("clip-test-live-file-\(UUID().uuidString).txt")
        try "test-payload".write(to: fixtureFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureFile) }

        let item = ClipboardItem(
            kind: .file,
            text: fixtureFile.path,
            filePaths: [fixtureFile.path]
        )

        ClipboardWriter.write(item, plain: false)

        let pb = TestIsolation.board
        XCTAssertEqual(pb.string(forType: .string), fixtureFile.path)
        let readURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertTrue(readURLs?.isEmpty ?? true, "File item must never place file URL objects on the pasteboard")
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertFalse(types.contains("public.file-url"), "File item must not advertise public.file-url")
        XCTAssertTrue(pb.types?.contains(.string) == true, "Pasteboard must include plain text type")
    }

    func test_clipboardWriter_liveFolder_writesOnlyPathString_andNoDirectoryPayloadOrFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fixtureFolder = tempDir.appendingPathComponent("clip-test-live-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureFolder) }

        let item = ClipboardItem(
            kind: .folder,
            text: fixtureFolder.path,
            filePaths: [fixtureFolder.path]
        )

        ClipboardWriter.write(item, plain: false)

        let pb = TestIsolation.board
        XCTAssertEqual(pb.string(forType: .string), fixtureFolder.path)
        let readURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertTrue(readURLs?.isEmpty ?? true, "Folder item must never place directory URL objects on the pasteboard")
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertFalse(types.contains("public.file-url"), "Folder item must not advertise public.file-url")
        XCTAssertTrue(pb.types?.contains(.string) == true, "Pasteboard must include plain text type")
    }

    func test_clipboardWriter_stalePath_writesPathStringWithoutRequiringExistence_andNoFileURL() {
        let stalePath = "/tmp/clip-nonexistent-path-\(UUID().uuidString).txt"
        let item = ClipboardItem(
            kind: .file,
            text: stalePath,
            filePaths: [stalePath]
        )

        ClipboardWriter.write(item, plain: false)

        let pb = TestIsolation.board
        XCTAssertEqual(pb.string(forType: .string), stalePath, "Stale path must still produce plain text path")
        let readURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertTrue(readURLs?.isEmpty ?? true, "Stale path must never produce a file URL object")
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertFalse(types.contains("public.file-url"), "Stale path must not advertise public.file-url")
    }

    func test_clipboardWriter_plainTextPaste_writesSamePathString_andNoFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fixtureFile = tempDir.appendingPathComponent("clip-test-plain-file-\(UUID().uuidString).txt")
        try "test-payload".write(to: fixtureFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureFile) }

        let item = ClipboardItem(
            kind: .file,
            text: fixtureFile.path,
            filePaths: [fixtureFile.path]
        )

        ClipboardWriter.write(item, plain: true)

        let pb = TestIsolation.board
        XCTAssertEqual(pb.string(forType: .string), fixtureFile.path)
        let readURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertTrue(readURLs?.isEmpty ?? true, "Plain paste must not write file URLs")
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertFalse(types.contains("public.file-url"))
    }

    func test_clipboardWriter_legacyItemWithEmptyFilePaths_writesTextFallback() {
        let legacyItem = ClipboardItem(
            kind: .file,
            text: "/legacy/document.pdf",
            filePaths: []
        )

        ClipboardWriter.write(legacyItem, plain: false)

        let pb = TestIsolation.board
        XCTAssertEqual(pb.string(forType: .string), "/legacy/document.pdf")
        let readURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertTrue(readURLs?.isEmpty ?? true)
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertFalse(types.contains("public.file-url"))
    }

    func test_clipboardWriter_emptyPath_leavesBoardUntouched_andReportsNotice() {
        let pb = TestIsolation.board
        pb.clearContents()
        pb.setString("sentinel-value", forType: .string)

        let emptyItem = ClipboardItem(
            kind: .file,
            text: "",
            filePaths: []
        )

        ClipboardWriter.write(emptyItem, plain: false)

        XCTAssertEqual(pb.string(forType: .string), "sentinel-value", "Empty path must leave existing pasteboard contents untouched")
    }

    // MARK: - Video Control Test (Preserves File Reference Behavior)

    func test_clipboardWriter_videoControl_writesFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fixtureVideo = tempDir.appendingPathComponent("clip-test-video-\(UUID().uuidString).mp4")
        try "video-content".write(to: fixtureVideo, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureVideo) }

        let item = ClipboardItem(
            kind: .video,
            text: fixtureVideo.path,
            filePaths: [fixtureVideo.path]
        )

        ClipboardWriter.write(item, plain: false)

        let pb = TestIsolation.board
        let readURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(readURLs?.count, 1, "Video item must write file URL")
        XCTAssertEqual(readURLs?.first?.path, fixtureVideo.path)
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertTrue(types.contains("public.file-url"), "Video item must advertise public.file-url")
        XCTAssertEqual(pb.string(forType: .string), fixtureVideo.path)
    }

    // MARK: - copyOnly Tests

    @MainActor
    func test_copyOnly_fileAndFolder_writesOnlyPathString() {
        let store = HistoryStore.shared

        let fileItem = ClipboardItem(kind: .file, text: "/tmp/copy-file.txt", filePaths: ["/tmp/copy-file.txt"])
        store.copyOnly(fileItem)

        let pb = TestIsolation.board
        XCTAssertEqual(pb.string(forType: .string), "/tmp/copy-file.txt")
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertFalse(types.contains("public.file-url"))

        let folderItem = ClipboardItem(kind: .folder, text: "/tmp/copy-dir", filePaths: ["/tmp/copy-dir"])
        store.copyOnly(folderItem)

        XCTAssertEqual(pb.string(forType: .string), "/tmp/copy-dir")
        let folderTypes = pb.types?.map(\.rawValue) ?? []
        XCTAssertFalse(folderTypes.contains("public.file-url"))
    }
}
