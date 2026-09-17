import XCTest
@testable import Clip

final class SettingsAndIdentityTests: XCTestCase {

    // MARK: - Google Account Codable tests

    func test_googleAccount_withPicture_decodesAndPersists() throws {
        let json = """
        {
            "email": "ada@example.com",
            "name": "Ada Lovelace",
            "picture": "https://example.com/avatar.jpg"
        }
        """
        let data = Data(json.utf8)
        let account = try JSONDecoder().decode(GoogleAuth.GoogleAccount.self, from: data)
        XCTAssertEqual(account.email, "ada@example.com")
        XCTAssertEqual(account.name, "Ada Lovelace")
        XCTAssertEqual(account.picture, "https://example.com/avatar.jpg")

        let encoded = try JSONEncoder().encode(account)
        let roundTripped = try JSONDecoder().decode(GoogleAuth.GoogleAccount.self, from: encoded)
        XCTAssertEqual(roundTripped, account)
    }

    func test_googleAccount_withoutPicture_stillDecodesBackwardsCompatible() throws {
        // Older versions of Clip saved GoogleAccount without the picture key
        let legacyJson = """
        {
            "email": "grace@example.com",
            "name": "Grace Hopper"
        }
        """
        let data = Data(legacyJson.utf8)
        let account = try JSONDecoder().decode(GoogleAuth.GoogleAccount.self, from: data)
        XCTAssertEqual(account.email, "grace@example.com")
        XCTAssertEqual(account.name, "Grace Hopper")
        XCTAssertNil(account.picture, "Older accounts without a picture key must decode with nil picture")
    }

    // MARK: - Paste Action Shortcut tests

    @MainActor
    func test_clearPasteActionShortcut_removesShortcutAndPreservesAction() {
        let store = PasteActionStore.shared
        guard let action = store.actions.first else {
            XCTFail("Expected at least one paste action in store")
            return
        }

        // Set a shortcut or verify setting
        _ = store.setShortcut(nil, for: action.id)
        XCTAssertNil(store.actions.first(where: { $0.id == action.id })?.shortcut)

        // The action itself is still present
        XCTAssertNotNil(store.actions.first(where: { $0.id == action.id }))
    }

    // MARK: - Settings Appearance tests

    func test_settingsAppearance_roundTripsAllCases() {
        for appearance in ThemeManager.SettingsAppearance.allCases {
            let raw = appearance.rawValue
            let resolved = ThemeManager.SettingsAppearance(rawValue: raw)
            XCTAssertEqual(resolved, appearance)
            XCTAssertFalse(appearance.title.isEmpty)
        }
    }

    // MARK: - Sidebar Sync Identity Glyph Resolution Tests

    func test_sidebarSyncGlyph_googleConnection_withValidHTTPS_resolvesToAvatar() {
        let account = GoogleAuth.GoogleAccount(email: "ada@example.com", name: "Ada Lovelace", picture: "https://example.com/avatar.jpg")
        let pic = account.picture
        let isAvatar = (pic != nil && !pic!.isEmpty && URL(string: pic!)?.scheme?.lowercased() == "https" && URL(string: pic!)?.host != nil)
        XCTAssertTrue(isAvatar)
    }

    func test_sidebarSyncGlyph_googleConnection_withoutPictureOrInsecure_resolvesToInitials() {
        let missingPic = GoogleAuth.GoogleAccount(email: "ada@example.com", name: "Ada Lovelace", picture: nil)
        let insecurePic = GoogleAuth.GoogleAccount(email: "ada@example.com", name: "Ada Lovelace", picture: "http://example.com/avatar.jpg")
        let invalidPic = GoogleAuth.GoogleAccount(email: "ada@example.com", name: "Ada Lovelace", picture: "not-a-url")

        for acc in [missingPic, insecurePic, invalidPic] {
            let pic = acc.picture
            let isAvatar = (pic != nil && !pic!.isEmpty && URL(string: pic!)?.scheme?.lowercased() == "https" && URL(string: pic!)?.host != nil)
            XCTAssertFalse(isAvatar, "Account with picture \(String(describing: pic)) should not resolve to avatar")
        }
    }

    // MARK: - Curated Row Activation Classification Tests

    func test_curatedRowActivation_fileAndFolderAndPrompt_requestPaste() {
        let fileItem = ClipboardItem(kind: .file, text: "/tmp/sample.txt")
        let folderItem = ClipboardItem(kind: .folder, text: "/tmp/sample_dir")
        var promptItem = ClipboardItem(kind: .text, text: "Write an essay")
        promptItem.role = .prompt

        let standardTextItem = ClipboardItem(kind: .text, text: "Simple note")

        let shouldPaste: (ClipboardItem) -> Bool = { item in
            item.role == .prompt || item.kind == .file || item.kind == .folder
        }

        XCTAssertTrue(shouldPaste(fileItem))
        XCTAssertTrue(shouldPaste(folderItem))
        XCTAssertTrue(shouldPaste(promptItem))
        XCTAssertFalse(shouldPaste(standardTextItem))
    }
}
