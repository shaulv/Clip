import Foundation

/// Combines two histories without creating duplicates.
///
/// Merging one Mac's items into another's is the moment a clipboard manager
/// either earns trust or loses it. Appending both lists gives every item twice;
/// keeping one side throws away whatever the user configured on the other. So
/// two items that hold the same thing become one item that keeps the *most
/// configured* version of every field: if either copy is pinned the survivor is
/// pinned, a title beats no title, tags are pooled.
enum ItemMerge {

    /// What makes two items the same item.
    ///
    /// Not the id — the same text copied on two Macs has two ids and is plainly
    /// one thing to the user. The payload is the identity.
    static func identity(_ item: ClipboardItem) -> String {
        let kind = item.kind.filterCategory.rawValue
        // The user's own name for the item is part of what it IS.
        //
        // This started as a carve-out for empty notes: a note or prompt
        // created and not yet written in has no body at all, so every one of
        // them shared the identity "text|" - three differently-named empty
        // notes collapsed into one and two of them were silently destroyed by
        // the first sync that saw them. With no payload to compare, the name
        // was the only thing that distinguished them.
        //
        // The same argument holds when there IS a body, and not naming it cost
        // real data (M20/S1). `duplicate(_:)` exists to make a second row with
        // the same payload on purpose; with only the payload in the identity,
        // "Note" and "Note copy" were one item, so the edit fold destroyed the
        // copy on the next Save and sync pushed the tombstone to the other Mac.
        // A name the user typed is a decision, and two differently-named rows
        // are two rows.
        //
        // Capture is unaffected, which is the case dedup is actually for:
        // captured clips carry no title, so both sides contribute "" here and
        // copying the same thing twice still folds exactly as before.
        let name = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.kind {
        case .color, .colorData:
            return "\(kind)|\(item.hexColor?.lowercased() ?? "")|\(name)"
        case .image, .video:
            // The filename stands in for the payload. Note that `MediaStore`
            // names files by UUID, not by a hash of their bytes, so this is
            // only ever true of rows that were COPIED from one another
            // (`duplicate`, a fold, a sync round trip) - two separate captures
            // of the same picture get two names and stay two items. M20/S5's
            // shared-file case reaches this the first way, not the second.
            return "\(kind)|\(item.imageFile ?? "")|\(item.filePaths.sorted().joined(separator: "\u{1}"))|\(name)"
        case .file, .folder:
            return "\(kind)|\(item.filePaths.sorted().joined(separator: "\u{1}"))|\(name)"
        default:
            let body = item.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                return "\(kind)|untitled|\(name)"
            }
            return "\(kind)|\(body)|\(name)"
        }
    }

    /// One item carrying the best of both.
    ///
    /// Order-independent by construction: every rule below picks by value, not
    /// by which argument came first, so `combine(a, b)` and `combine(b, a)`
    /// agree. Sync would otherwise settle differently on each Mac.
    static func combine(_ a: ClipboardItem, _ b: ClipboardItem) -> ClipboardItem {
        // Which side is "the recent one" has to be a total order, or
        // combine(a, b) and combine(b, a) can disagree and the two Macs settle
        // differently for ever. `updatedAt` decides; the id breaks an exact tie.
        let aWins = (a.updatedAt, a.id.uuidString) >= (b.updatedAt, b.id.uuidString)
        let (recent, stale) = aWins ? (a, b) : (b, a)

        // The older id survives, so a shortcut or a link recorded against it
        // still resolves after the merge.
        let (older, newer) = a.timestamp <= b.timestamp ? (a, b) : (b, a)
        var out = older

        out.timestamp = newer.timestamp            // most recently used leads the sort
        out.updatedAt = max(a.updatedAt, b.updatedAt)

        // Flags and counters: the most configured of the two, which is what was
        // asked for - a pin on either Mac is a pin.
        out.isPinned = a.isPinned || b.isPinned
        out.isFavorite = a.isFavorite || b.isFavorite
        out.useCount = max(a.useCount, b.useCount)
        out.pinnedIndex = min(a.pinnedIndex, b.pinnedIndex)
        out.tags = Array(Set(a.tags).union(b.tags)).sorted()

        // A prompt that also exists as a plain clip is a prompt: the user
        // curated it once, and demoting it would silently undo that.
        out.role = a.role.isCurated ? a.role : b.role

        // Content follows the clock instead.
        //
        // Choosing the *longer* string, which is what this did for every field
        // alike, means editing a note down to a shorter sentence loses to the
        // older, longer copy: the edit appears to work and the next sync undoes
        // it. Whichever side was edited more recently owns the words, and the
        // other only fills a gap.
        out.text = preferred(recent.text, stale.text)
        out.title = preferred(recent.title, stale.title)
        out.shortcut = preferred(recent.shortcut, stale.shortcut)
        out.language = preferred(recent.language, stale.language)
        out.sourceApp = preferred(recent.sourceApp, stale.sourceApp)
        out.sourceAppName = preferred(recent.sourceAppName, stale.sourceAppName)
        out.hexColor = preferred(recent.hexColor, stale.hexColor)
        out.imageFile = preferred(recent.imageFile, stale.imageFile)
        out.platform = recent.platform ?? stale.platform
        out.richText = recent.richText ?? stale.richText
        out.pixelWidth = recent.pixelWidth ?? stale.pixelWidth
        out.pixelHeight = recent.pixelHeight ?? stale.pixelHeight
        out.filePaths = recent.filePaths.isEmpty ? stale.filePaths : recent.filePaths

        return out
    }

    /// The first non-empty value, falling back to the second.
    ///
    /// Called with the newer side first for content, so recency decides and the
    /// older copy only fills a gap. For everything else the two are equivalent.
    private static func preferred(_ a: String?, _ b: String?) -> String? {
        let x = (a?.isEmpty == false) ? a : nil
        let y = (b?.isEmpty == false) ? b : nil
        guard let x else { return y }
        guard y != nil else { return x }
        return x
    }

    /// Folds a list onto itself, collapsing every duplicate.
    static func deduplicate(_ items: [ClipboardItem]) -> [ClipboardItem] {
        merge(items, into: []).items
    }

    /// The result of a merge: the list, and the ids that were folded away.
    struct Result {
        let items: [ClipboardItem]
        /// Ids that lost their identity to another item and no longer exist.
        ///
        /// The caller has to tell the server about these. Without them the merge
        /// is only local: the server keeps all the duplicates, hands them back on
        /// every sync, and the two sides disagree about how many items there are
        /// for ever.
        let absorbed: [UUID]
    }

    /// Merges `incoming` into `existing`, in `existing`'s order, with anything
    /// genuinely new appended.
    ///
    /// Matching happens by **id first**, then by payload. Both are needed:
    ///
    /// - By id, because the same item edited on another Mac arrives with a
    ///   different body. Matching only on payload would file it as a new item
    ///   *and* leave the old one, giving two rows with one id.
    /// - By payload, because the same text copied separately on two Macs has two
    ///   ids and is plainly one thing to the user.
    static func merge(_ incoming: [ClipboardItem], into existing: [ClipboardItem]) -> Result {
        var order: [String] = []
        var byKey: [String: ClipboardItem] = [:]
        var keyForID: [UUID: String] = [:]
        var absorbed: Set<UUID> = []
        // The earliest ORIGINAL timestamp folded into each entry, and the id
        // that came with it.
        //
        // `combine` picks the surviving id by `timestamp` and then overwrites
        // `out.timestamp` with the NEWER of the two - so the one field that
        // chose the id is destroyed by the very fold that used it. Fold a
        // third copy in and a different id wins, which is not a hypothetical:
        // sync pushes the local row, the server hands the same row back with
        // its timestamp truncated to whole seconds, and folding that echo onto
        // an already-combined entry flipped the survivor from the older id to
        // the one that had just been absorbed. The model then held one id
        // while Carbon held a hotkey registered against the other, so a
        // per-item shortcut that had just survived a sync pressed into
        // nothing. Deciding from the untouched originals keeps the fold
        // idempotent however many times a copy comes round again.
        var earliest: [String: (id: UUID, at: Date)] = [:]

        /// The id this entry keeps, once `item` has been folded into it.
        func survivingID(_ key: String, _ item: ClipboardItem) -> UUID {
            guard let held = earliest[key] else {
                earliest[key] = (item.id, item.timestamp)
                return item.id
            }
            // The same total order `combine` documents: oldest wins, and the
            // id breaks an exact tie, so two Macs never settle differently.
            if (held.at, held.id.uuidString) <= (item.timestamp, item.id.uuidString) {
                return held.id
            }
            earliest[key] = (item.id, item.timestamp)
            return item.id
        }

        for item in existing + incoming {
            // Same id: the same item, whatever its payload says now.
            if let key = keyForID[item.id], let seen = byKey[key] {
                var combined = combine(seen, item)
                combined.id = survivingID(key, item)
                byKey[key] = combined
                for id in [seen.id, item.id] where id != combined.id { absorbed.insert(id) }
                keyForID[seen.id] = key
                keyForID[item.id] = key
                keyForID[combined.id] = key
                continue
            }
            let key = identity(item)
            if let seen = byKey[key] {
                var combined = combine(seen, item)
                combined.id = survivingID(key, item)
                byKey[key] = combined
                // Whichever id did not survive is gone, and has to be reported.
                for id in [seen.id, item.id] where id != combined.id { absorbed.insert(id) }
                // Both sides' ids now lead to this entry, so a later copy of
                // either one lands here rather than starting a third.
                keyForID[seen.id] = key
                keyForID[item.id] = key
                keyForID[combined.id] = key
            } else {
                byKey[key] = item
                keyForID[item.id] = key
                _ = survivingID(key, item)
                order.append(key)
            }
        }
        let merged = order.compactMap { byKey[$0] }
        let survivors = Set(merged.map(\.id))
        return Result(items: merged, absorbed: absorbed.subtracting(survivors).sorted { $0.uuidString < $1.uuidString })
    }
}
