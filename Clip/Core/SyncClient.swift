import Foundation

/// Talks to the sync service.
///
/// The service is deliberately **not part of Clip**: it runs as its own process
/// with its own database (`sync-server/`), and speaks the same HTTP API a hosted
/// deployment will speak. Moving to a real domain is then a URL change, not a
/// rewrite.
@MainActor
final class SyncClient {

    static let shared = SyncClient()
    private init() {}

    /// Where this Mac's sync service lives, or nil when none is set.
    ///
    /// There is deliberately **no built-in default**. An earlier build shipped
    /// one particular domain, which meant anybody else running Clip would have
    /// synced their clipboard into somebody else's database - a privacy problem
    /// and a bill, neither of them theirs. Every install now points at a server
    /// its owner set up, and until it does, sync is off rather than pointed
    /// somewhere arbitrary.
    var baseURL: URL? {
        switch SyncManager.shared.serviceKind {
        case .official:
            // Clip's own service, compiled in. The user configures nothing and
            // is shown nothing, because there is nothing here for them to get
            // right or wrong.
            return OfficialService.url
        case .personal:
            guard let stored = Database.shared.preference("syncBaseURL"), !stored.isEmpty else {
                return nil
            }
            return URL(string: stored)
        }
    }

    /// The user's own server, whatever mode is in force.
    ///
    /// The Server settings edit this one specifically. Reading `baseURL` there
    /// would show the official address to somebody signed in with Google, which
    /// is exactly what must not happen.
    var personalURL: URL? {
        guard let stored = Database.shared.preference("syncBaseURL"), !stored.isEmpty else {
            return nil
        }
        return URL(string: stored)
    }

    static let local = URL(string: "http://127.0.0.1:8787")!

    /// True when the service in force has an address to talk to.
    ///
    /// Always true under Google, because the address ships with the app - which
    /// is the point of the official service: there is no setup step to get
    /// wrong before signing in.
    var isConfigured: Bool { baseURL != nil }

    /// True when the user has configured a server of their own.
    var hasPersonalServer: Bool { personalURL != nil }

    /// True when this Mac is pointed at a service on this machine.
    var isLocalService: Bool {
        let host = baseURL?.host ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Asks the server whether it is there and working.
    ///
    /// `/health` needs no token and touches no data, so it separates "the address
    /// is wrong" from "the token is wrong" - two problems that otherwise present
    /// identically as sync not working.
    func testConnection() async -> Result<String, Error> {
        guard let baseURL else {
            return .failure(SyncError.server("No server address is set yet."))
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/health"))
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(SyncError.server("No answer from \(baseURL.host ?? "the server")."))
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard http.statusCode == 200, json?["service"] as? String == "clip-sync" else {
                return .failure(SyncError.server("""
                    \(baseURL.host ?? "That address") answered, but not as a Clip sync \
                    server (HTTP \(http.statusCode)). Check the address ends in \
                    /clipassets/api.
                    """))
            }
            return .success("Your server answered. You can create a token now.")
        } catch {
            return .failure(SyncError.server("""
                Could not reach \(baseURL.host ?? "that address"): \
                \(error.localizedDescription)
                """))
        }
    }

    private var token: String? { SyncManager.shared.token }

    private var deviceBody: [String: Any] {
        ["device": SyncManager.shared.deviceName, "deviceID": SyncManager.shared.deviceID]
    }

    // MARK: - Tokens

    /// Creates a new sync space. The token is returned once and never again.
    func createSpace() async throws -> (token: String, space: SyncSpace) {
        let json = try await post("/token/create", body: deviceBody, authorised: false)
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw SyncError.server("The sync service returned no token.")
        }
        return (token, try Self.space(from: json))
    }

    /// Trades a Google identity for the sync token that account owns.
    ///
    /// Unauthenticated on purpose: the identity token *is* the credential, and
    /// there is no sync token yet to authorise with. The server verifies the
    /// identity against Google's published keys before it hands anything back.
    func signInWithGoogle(grant: GoogleAuth.Grant) async throws -> (token: String, email: String,
                                                                    name: String, picture: String?,
                                                                    space: SyncSpace) {
        var body = deviceBody
        // The code, not an identity. Redeeming it needs the client secret, and
        // the whole point of doing that on the server is that the secret is not
        // in the app to send.
        body["code"] = grant.code
        body["codeVerifier"] = grant.verifier
        body["redirectUri"] = grant.redirect
        let json = try await post("/auth/google", body: body, authorised: false)
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw SyncError.server("The sync service returned no token for that account.")
        }
        return (token,
                json["email"] as? String ?? "",
                json["name"] as? String ?? "",
                json["picture"] as? String,
                try Self.space(from: json))
    }

    /// Unlinks the Google account from its space. The data stays.
    func forgetGoogle() async throws {
        _ = try await post("/auth/google/forget", body: deviceBody)
    }

    /// Registers this Mac against the current token and reads the space back.
    ///
    /// Also serves as "is this token real?", which is why connecting calls it
    /// before touching any local data.
    @discardableResult
    func claim() async throws -> SyncSpace {
        var body = deviceBody
        // Carries the id this Mac used before it started deriving one from the
        // hardware, so the server renames that row instead of adding a second
        // Mac beside it on the day of the upgrade.
        if let previous = SyncManager.shared.previousDeviceID { body["replaces"] = previous }
        let space = try Self.space(from: try await post("/token/claim", body: body))
        SyncManager.shared.clearPreviousDeviceID()
        return space
    }

    /// Every Mac this token has been used from.
    ///
    /// The space summary only ever carried a COUNT, which is unusable the
    /// moment one of the Macs is a machine the owner does not recognise.
    func devices() async throws -> [SyncDevice] {
        let json = try await get("/token/devices")
        let rows = json["devices"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["deviceID"] as? String, !id.isEmpty else { return nil }
            return SyncDevice(id: id,
                              name: row["name"] as? String ?? "Mac",
                              lastSeen: Date(timeIntervalSince1970:
                                                row["lastSeen"] as? Double ?? 0))
        }
    }

    /// Signs another Mac out. `proof` carries a fresh Google grant, which the
    /// server checks against the account this space belongs to - the sync
    /// token alone is deliberately not enough to evict another Mac.
    func forgetDevice(_ deviceID: String, proof: GoogleAuth.Grant?) async throws {
        var body = deviceBody
        body["deviceID"] = deviceID
        body["selfDeviceID"] = SyncManager.shared.deviceID
        if let proof {
            body["code"] = proof.code
            body["codeVerifier"] = proof.verifier
            body["redirectUri"] = proof.redirect
        }
        _ = try await post("/token/forget", body: body)
    }

    func setSharing(_ shared: Bool) async throws -> SyncSpace {
        try Self.space(from: try await post("/token/sharing", body: ["shared": shared]))
    }

    /// Removes this Mac from the space. The token stays valid for the others.
    func forgetDevice() async throws {
        _ = try await post("/token/forget", body: deviceBody)
    }

    private static func space(from json: [String: Any]) throws -> SyncSpace {
        guard let raw = json["space"] as? [String: Any], let id = raw["id"] as? String else {
            throw SyncError.server("The sync service returned an unexpected response.")
        }
        let formatter = ISO8601DateFormatter()
        return SyncSpace(
            id: id,
            shared: raw["shared"] as? Bool ?? true,
            devices: raw["devices"] as? Int ?? 1,
            items: raw["items"] as? Int ?? 0,
            deletionRequestedAt: (raw["deletionRequestedAt"] as? String).flatMap(formatter.date(from:))
        )
    }

    // MARK: - Sync

    /// How much payload one request may carry.
    ///
    /// Not a limit on what can be stored - a limit on what one HTTP request may
    /// be. The live server refuses a body over roughly a megabyte whatever
    /// `post_max_size` claims, which is the kind of ceiling that only shows up
    /// against the real host: the same request passed every local test. 512 KB
    /// leaves room for JSON overhead and headers underneath it.
    private static let uploadBudget = 512 * 1024

    /// One record's worth of work: either a whole row, or one part of a big one.
    private struct Chunk {
        let row: [String: Any]
        let bytes: Int
    }

    /// Splits the history into requests that will actually be accepted.
    ///
    /// Two different problems in one pass. Many small items are grouped until
    /// the budget is reached. A single item *larger* than the budget cannot be
    /// grouped or shrunk, so it is cut into parts the server reassembles - the
    /// alternative is an item that fails identically for ever, which is exactly
    /// the ceiling this is all meant to remove.
    private func batched(_ rows: [[String: Any]]) -> [[[String: Any]]] {
        var batches: [[[String: Any]]] = []
        var current: [[String: Any]] = []
        var bytes = 0

        func flush() {
            if !current.isEmpty { batches.append(current); current = []; bytes = 0 }
        }

        for row in rows {
            let payload = row["payload"] as? String ?? ""
            let size = payload.utf8.count

            if size > Self.uploadBudget {
                flush()
                for part in Self.split(row, payload: payload) {
                    batches.append([part])          // one part per request
                }
                continue
            }
            if !current.isEmpty, bytes + size > Self.uploadBudget { flush() }
            current.append(row)
            bytes += size
        }
        flush()
        return batches
    }

    /// Cuts one row's payload into parts the server concatenates back together.
    ///
    /// Split on UTF-8 boundaries via the encoded bytes, then rebuilt as strings:
    /// slicing by character count would make the parts unpredictably sized, and
    /// slicing raw bytes carelessly would cut a multi-byte character in half.
    private static func split(_ row: [String: Any], payload: String) -> [[String: Any]] {
        var pieces: [String] = []
        var piece = ""
        var bytes = 0

        for character in payload {
            let size = String(character).utf8.count
            if bytes + size > uploadBudget, !piece.isEmpty {
                pieces.append(piece)
                piece = ""
                bytes = 0
            }
            piece.append(character)
            bytes += size
        }
        if !piece.isEmpty { pieces.append(piece) }

        return pieces.enumerated().map { index, text in
            var part = row
            part["payload"] = text
            part["part"] = index
            part["parts"] = pieces.count
            return part
        }
    }

    /// Pushes local changes, pulls remote ones, returns how many were applied.
    ///
    /// `merge` is passed down rather than read from the manager so the direction
    /// of a sync is always visible at the call site. With it off nothing is
    /// uploaded: the token's copy is the one the user asked to keep.
    @discardableResult
    func sync(merge: Bool) async throws -> Int {
        var applied = 0

        // Stamped before any work, not after it.
        //
        // Applying a page can itself create changes - folding a duplicate deletes
        // an item and records a tombstone. Stamping the watermark at the *end*
        // put those behind it, so they were never pushed and the server kept a
        // copy this Mac had already thrown away.
        let startedAt = Date()

        if merge {
            for batch in batched(localChanges()) {
                applied += try await exchange(changes: batch)
            }
        }

        // Only now, with every batch accepted, is it safe to say "everything up
        // to here has been sent". Moving it earlier would strand whatever was in
        // a batch that failed.
        //
        // And only when something was actually pushed. With merge off, this
        // stamped every local item as "sent" without a single upload - so
        // turning merge on afterwards uploaded nothing at all, because
        // `localChanges()` only offers what changed after the watermark. Those
        // items became invisible to sync permanently.
        if merge {
            Database.shared.setPreference("syncPushedAt",
                                          String(startedAt.timeIntervalSince1970))
        }
        Database.shared.pruneTombstones()

        // Then read forward until the cursor stops moving. The second condition
        // is the one that matters: a server that keeps answering "there is more"
        // without advancing the cursor would otherwise loop for ever.
        for _ in 0..<512 {
            let before = Database.shared.preference("syncCursor") ?? "0"
            let (count, hasMore) = try await page()
            applied += count
            let after = Database.shared.preference("syncCursor") ?? "0"
            if !hasMore || after == before { break }
        }
        return applied
    }

    /// One request: send these changes, apply what comes back.
    @discardableResult
    private func exchange(changes: [[String: Any]]) async throws -> Int {
        try await page(changes: changes).0
    }

    private func page(changes: [[String: Any]] = []) async throws -> (Int, Bool) {
        let cursor = Database.shared.preference("syncCursor") ?? "0"
        let json = try await post("/sync", body: ["since": cursor, "changes": changes])

        let remote = json["changes"] as? [[String: Any]] ?? []
        let lastApplied = applyRemote(remote)
        // The server's cursor only if nothing was skipped. Otherwise the
        // sequence of the last row that actually landed, so the failed row is
        // offered again next time instead of being lost in silence.
        if lastSkipped.isEmpty, let next = json["cursor"] as? String {
            Database.shared.setPreference("syncCursor", next)
        } else if let lastApplied, !lastApplied.isEmpty {
            Database.shared.setPreference("syncCursor", lastApplied)
        }

        // A push writes rows and the same response hands them straight back.
        // Counting those as changes received made every sync look busy, so a
        // sync that was genuinely doing nothing was impossible to tell from one
        // that was stuck.
        let sent = Set(changes.compactMap { $0["id"] as? String })
        let fromElsewhere = remote.filter { !sent.contains($0["id"] as? String ?? "") }

        // The local service answers without `hasMore`; one page is all of it.
        return (fromElsewhere.count, json["hasMore"] as? Bool ?? false)
    }

    /// Everything on this Mac, as sync rows: what is here, and what was removed.
    ///
    /// `updatedAt` rather than `timestamp` is the whole reason edits work. The
    /// server keeps whichever copy is newer, and `timestamp` never moves after
    /// capture - so every edit arrived looking older than what was already there
    /// and was thrown away.
    private func localChanges() -> [[String: Any]] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Only what has actually changed since the last successful push.
        //
        // Sending the whole history once a minute is not just wasteful - the
        // server accepts anything it considers newer, hands it straight back in
        // the same response, and the app counts that as work done. The result was
        // "Synced 15 changes" for ever with nothing changing, which is
        // indistinguishable from a sync that is broken.
        let watermark = Double(Database.shared.preference("syncPushedAt") ?? "0") ?? 0
        let since = Date(timeIntervalSince1970: watermark)

        // `isLocalOnly` items (image, video, file, folder - anything pointing
        // at a path specific to this Mac) never leave via this channel. See
        // `ClipboardItem.isLocalOnly` for the user's own words on why: a path
        // or a filename means nothing, or means something else entirely, on
        // any other Mac.
        var rows: [[String: Any]] = HistoryStore.shared.items
            .filter { !$0.isLocalOnly && (watermark == 0 || $0.updatedAt > since) }
            .compactMap { item in
            guard let data = try? encoder.encode(item),
                  let payload = String(data: data, encoding: .utf8) else { return nil }
            return [
                "entity": "item",
                "id": item.id.uuidString,
                "updated_at": item.updatedAt.timeIntervalSince1970,
                "deleted": false,
                "payload": payload
            ]
        }

        // Settings ride the same channel on a slower clock. `SettingsSync`
        // decides whether one is due; this only asks. Keeping the decision
        // there rather than here is what lets the cadence be a user setting
        // without the transport knowing anything about it.
        if let row = SettingsSync.shared.pendingRow() { rows.append(row) }

        // A deletion is a change too. Without these the other Macs never learn,
        // and the item comes back here the next time the cursor resets. Sending
        // them again is harmless: their time never moves, so the server keeps the
        // copy it already has and writes nothing.
        //
        // Every tombstone is pushed, local-only ones included. The user's
        // rule (02/09): a file-backed clip lives only on the Mac that copied
        // it, and any copy of it on the server or another Mac is a broken
        // path to be deleted. So a tombstone for one is exactly the news the
        // server needs, to drop the legacy row it still holds.
        let present = Set(HistoryStore.shared.items.map(\.id))
        for tombstone in Database.shared.tombstones()
        where !present.contains(tombstone.id) && (watermark == 0 || tombstone.deletedAt > since) {
            rows.append([
                "entity": "item",
                "id": tombstone.id.uuidString,
                "updated_at": tombstone.deletedAt.timeIntervalSince1970,
                "deleted": true,
                "payload": NSNull()
            ])
        }
        return rows
    }

    /// Applies one page of rows from the server.
    ///
    /// Always a merge, never a replace, even when the user chose "replace this
    /// Mac's items". Replacing happens **once**, before the first request, in
    /// `SyncManager.connect`. Doing it per page would have made page two throw
    /// away page one, so a large history would arrive with only its last page
    /// intact - and it would have looked like an ordinary short sync.
    ///
    /// Arriving items go through `ItemMerge` rather than straight into the list.
    /// The same clip copied on two Macs has two different ids and is plainly one
    /// thing to the user; appending it twice is the failure this guards against,
    /// and it also means a pin or a title set on either Mac survives.
    /// Rows the last page could not apply, and the sequence to stop the cursor
    /// at because of them.
    ///
    /// Skipping a row and advancing the cursor past it loses it for ever, in
    /// silence: an unknown entity, a bad id, a missing payload or a payload that
    /// will not decode all fell through a bare `continue`. Nothing counted them,
    /// nothing logged them, and the row was never offered again. Now the cursor
    /// stops at the last row that actually landed, so the next sync tries again.
    private(set) var lastSkipped: [(seq: String, reason: String)] = []

    @discardableResult
    private func applyRemote(_ rows: [[String: Any]]) -> String? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let store = HistoryStore.shared

        var incoming: [ClipboardItem] = []
        lastSkipped = []
        // The sequence of the last row that was genuinely applied. The cursor
        // may not go past it.
        var lastApplied: String?
        // Once a row is skipped, no later row may advance the cursor either -
        // the cursor is a single number, and moving it past a failure would
        // strand that failure whatever happened after it.
        var stopped = false

        func seq(_ row: [String: Any]) -> String {
            (row["seq"] as? String) ?? (row["seq"] as? Int).map(String.init) ?? ""
        }
        func skip(_ row: [String: Any], _ reason: String) {
            stopped = true
            lastSkipped.append((seq: seq(row), reason: reason))
            Database.shared.log("sync", "skipped \(seq(row)): \(reason)")
        }
        func applied(_ row: [String: Any]) {
            if !stopped { lastApplied = seq(row) }
        }

        for row in rows {
            // One settings row per space, last write wins by its own timestamp.
            if row["entity"] as? String == "settings" {
                SettingsSync.shared.applyRemote(row)
                applied(row)
                continue
            }
            guard row["entity"] as? String == "item" else {
                // A row type this build does not understand. Not an error, but
                // not applied either, so the cursor must not pass it: a newer
                // build has to be able to come along and pick it up.
                skip(row, "unknown entity \(row["entity"] as? String ?? "nil")")
                continue
            }
            guard let idString = row["id"] as? String,
                  let id = UUID(uuidString: idString) else {
                skip(row, "unusable id")
                continue
            }

            if row["deleted"] as? Bool == true {
                // `recordDeletion: false` because the server is the one telling
                // us. Recording a tombstone here pushed the deletion straight
                // back, which bumped the server row's sequence, which made it
                // look new on the next pull - so every sync moved the same rows
                // for ever and reported dozens of changes with nothing changing.
                store.delete(id, recordDeletion: false)
                applied(row)
                continue
            }
            guard let payload = row["payload"] as? String,
                  let data = payload.data(using: .utf8) else {
                skip(row, "no payload")
                continue
            }
            guard let item = try? decoder.decode(ClipboardItem.self, from: data) else {
                // The shape a truncated multipart upload produces. Trying again
                // next time is the only chance this row has.
                skip(row, "payload would not decode")
                continue
            }

            // File-backed clips are local-only (M5 REVISED): a path or a
            // filename means nothing, or means something else, on this Mac.
            // An up-to-date client never pushes one of these, but an older
            // client might still have one sitting in its outbox - not a
            // corrupt row, just one this Mac must not adopt. The cursor still
            // advances past it.
            if item.isLocalOnly {
                // Not adopted, and not left on the server either: a tombstone
                // recorded here is pushed on the next sync and deletes the
                // legacy row everywhere (the user's rule, 02/09: a broken
                // path is deleted, locally and in the cloud).
                Database.shared.recordTombstone(item.id)
                applied(row)
                continue
            }

            // Last write wins per id, but the losing text is kept as a version:
            // Clip already records every revision, and sync should feed that
            // history rather than quietly destroy one side of a conflict.
            if let existing = store.item(id), existing.fullText != item.fullText,
               item.timestamp > existing.timestamp {
                Database.shared.addVersion(for: existing, body: existing.fullText,
                                           title: existing.title, note: "Replaced by sync")
            }
            incoming.append(item)
            applied(row)
        }

        if !incoming.isEmpty { store.merge(incoming) }
        return lastApplied
    }

    // MARK: - Deletion

    /// Marks the space deleted. The server keeps the data for a grace period so
    /// a hostile or mistaken deletion can be undone.
    func requestDeletion() async throws -> String {
        let json = try await post("/space/delete", body: [:])
        return json["purgeAt"] as? String ?? "in 30 days"
    }

    func cancelDeletion() async throws {
        _ = try await post("/space/delete/cancel", body: [:])
    }

    // MARK: - Transport

    @discardableResult
    /// The read half of `post`, for the endpoints that only ever read.
    private func get(_ path: String) async throws -> [String: Any] {
        guard let baseURL else { throw SyncError.server("No sync server is set up yet.") }
        guard let token else { throw SyncError.noToken }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.server("No response from the sync service.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String {
                throw SyncError.server(message)
            }
            throw SyncError.server("The sync service returned \(http.statusCode).")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func post(_ path: String, body: [String: Any], authorised: Bool = true) async throws -> [String: Any] {
        guard let baseURL else { throw SyncError.server("No sync server is set up yet.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        if authorised {
            guard let token else { throw SyncError.noToken }
            // The token is the only thing that scopes the request to this space.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.server("No response from the sync service.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The service explains itself; pass that through rather than a code.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String {
                throw SyncError.server(message)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.server("The sync service returned \(http.statusCode). \(text.prefix(160))")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
