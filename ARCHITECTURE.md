# How Clip is put together

This document explains the shape of the code and, where a decision is not
obvious, why it is that way. Most of these were arrived at by getting it wrong
first, and those cases are worth more than the ones that were right immediately.

## The one rule everything else serves

**Nothing expensive on the capture path.** Copying is the thing the user does
hundreds of times a day without thinking about it, and the moment it stutters
the app is worse than no app. So capture is: read the pasteboard, classify it,
insert it, return. No model call, no network, no full-library scan.

That rule is why deduplication is an index lookup rather than a comparison
against every stored item, and why the save is a diff rather than a rewrite.
Both of those started out the other way and both were on the copy path.

## The layers

```
   ClipboardMonitor          polls the pasteboard, classifies, hands over
          |
     HistoryStore            the single source of truth for items and view state
       /      \
 Database      SyncManager   SQLite (own serial queue) | the network, three ways
       |            |
   AppPaths     SyncClient
                    |
        OfficialService / ServerConfig
```

Views observe `HistoryStore` and `ThemeManager`. Nothing in `Views/` talks to
`Database` directly.

## Paste actions

Four files, one direction of dependency, and the reason they are separate:

```
   PasteActionStore      what the menu contains, in what order (persisted)
          |
   PasteActionMenu       an NSMenu built from the store, popped at the pointer
          |
   PasteTransform        read text -> ask the model -> paste into the target app
          |
   PasteKeystroke        the ⌘V, with exactly one owner
```

- **The store is the only source of truth.** Settings writes it; the menu reads
  it. Nothing in between gets an opinion, which is what makes a reorder in
  Settings trustworthy at the pointer.
- **The instruction lives with the action**, not at the call site. There are
  three callers, and the first draft had the wording in two of them - which is
  how a menu item and the translation it produces come to disagree about which
  direction they go.
- **The menu is an `NSMenu`, deliberately.** This app is an agent with no key
  window: a custom SwiftUI overlay has to be given focus, kept key, and taught
  arrow keys, Escape and click-outside, and every one of those has already been
  a bug here. An `NSMenu` runs its own event loop and arrives with all of it
  working, including from a global hotkey with nothing on screen.
- **Failure never touches the pasteboard.** The write and the keystroke happen
  only after a usable reply, because a transform that ate the clipboard and gave
  nothing back is worse than no feature.

## Notices

`NoticeCenter` is the one place the app says something about itself, and since
02/09/2026 it has three lifetimes instead of one timer. `.transient` is news (a
paste that failed) and clears after twelve seconds. `.persistent` is a condition
(sync cannot reach the server, a saved key cannot be read): it stays until the
owner calls `resolve(key)`, can be dismissed for the launch, and lights the
menu-bar badge so it is discoverable with the panel shut. `.integrity` is data
at risk (the database would not open, a migration failed, a reconcile refused
to delete): not dismissible, outranks everything, and raises one alert per
launch when no panel is open. A notice carries at most one `Action`; the bar
renders it as the capsule button that used to be hard-wired to "Turn on AI".
Every subsystem reports through this door: `AIDiagnosis` reads provider errors,
`StorageDiagnosis` reads file and database failures, sync reports with the key
`sync.failure`. The Diagnostics window (menu-bar icon, Settings > Privacy, the
"+N more" link in the bar) lists every open notice and the last 200 rows of the
activity log; `DiagnosticsReport.full()` is the copyable text behind it.

The rule behind all of it: a `guard … else { return }` with no feedback on a
user-triggered or startup path is a defect even when the code is right. In
practice, probe section 134 (`run_m4_silent_paths`) enforces that rule today
against a named list of 15 functions only, out of well over 1,000 in the
Swift tree - it fails the suite on a new unallowlisted silent guard inside
those 15.
Widening the gate to the rest of the codebase (roughly 155 `try?` sites and
several hundred bare `guard ... else { return }` sites live outside it) is
planned, not done. See `START-HERE.md` and the function's own docstring in
`qa-probe.py` for the current list and the reasoning per entry.

## Startup health and recovery

`StartupHealth.run()` executes in `applicationDidFinishLaunching` before
`Migration.runIfNeeded()`. It compares the bundle version with the last-run
stamp (kept in both the preferences table and UserDefaults, because the one
time the stamp matters most is when the database will not open), writes a
`VACUUM INTO` backup before any migration, runs the `PRAGMA user_version`
ladder inside a transaction, and audits the data folder for orphans (media no
item points at, stale test files, superseded installs beyond the newest two).
`Database.open()` runs `quick_check` and restores the newest backup rather than
starting empty; `reconcileItems` refuses to tombstone when nothing decoded or
when the removal count exceeds max(10, 5 %), because a transient decode bug
must never become a permanent, server-propagated delete. Reclaim MOVES orphans
into a dated `Reclaimed-*` folder; nothing is deleted until the user empties it.

The Keychain repairs itself in stages (`KeychainStore.selfRepair`): drop the
negative cache and re-read, then a non-interactive delete-and-add under the
current signature with the `SecItemAdd` status checked and the value read back,
and only then a persistent notice whose action runs the interactive path. The
sync token is never deleted by disconnecting; a fingerprint in the preferences
table tells "lost the credential" apart from "never connected".

## HistoryStore, and why the list is memoised

`HistoryStore` publishes 24 properties. Most of them - the selected row, the
focused action, whether the detail overlay is open, which items are marked - have
nothing to do with *which items are visible*, but every one of them invalidates
every observing view.

`visibleItems` used to be a plain computed property: four chained filters and a
sort. So pressing the down arrow re-filtered and re-sorted the entire library,
three times, to arrive at exactly the list that was already on screen. Measured
at 745 items: ten arrow-key presses ran the pipeline **thirty** times.

It is now memoised behind `DerivationKey`, which names every genuine input:
content revision, query, tab, tab configuration revision, filter set, time
filter, sort order, search mode, pin revision. **Anything missing from that key
is a correctness bug**, so the rule is that a new input to
`computeVisibleItems` is added to the key in the same commit.

Two details in there that are not decoration:

- A **relative** time filter answers a different question as time passes. "Last
  24 hours" changes while nobody touches anything, so the key carries a
  one-minute bucket whenever such a filter is on. Bounded staleness on a window
  measured in hours, and no cost at all when the filter is off.
- The query is parsed **once per pass**, not once per item. It used to be
  lowercased and split per item, which is 745 identical pieces of work to answer
  a question about a string the user typed once.

`derivationAudit` in the QA bridge steps one input at a time with the rest held
fixed and compares the cached answer against a fresh computation. That shape is
deliberate: the first version varied two inputs at once, so the key always
changed, the cache never had the chance to be stale, and deliberately removing
`sortOrder` from the key did not fail it.

## Persistence: a diff, and who else writes

`save()` writes only what changed, against a watermark of id to `updatedAt`.
Every mutation funnels through `update()`, which stamps `updatedAt`, so that
comparison is reliable.

It used to re-encode and re-write **every item** for a single copy or pin
toggle, and it was upsert-only - it never deleted. So items dropped by `trim`
stayed on disk and came back on the next launch: `historyLimit` bounded memory
and nothing at all on disk.

The diff alone was not sufficient, because **this layer is not the only writer**.
`Database.addVersion` inserts an item row so its foreign key has something to
point at. `add()` was writing that version record against the *discarded*
duplicate, so every deduplicated copy left an orphan row that came back as a
real item after a restart - fifty copies of the same thing left fifty rows and
twenty-one items. Two fixes: version the item that actually survived, and
reconcile the stored set against the list on save, which cannot drift no matter
who writes.

## Themes, and resolving once

An `AppTheme` is a palette plus a set of *derived* colors. Derived means: nudge
this red until it clears the contrast ratio on every ground it is painted on.
That is a search, it converts colors to hex strings and parses them back, and it
runs up to twelve times per answer.

Written as computed properties, that search ran on **every read**. Measured at
0.62 ms for one row's worth of colors, so thirty visible rows spent roughly
18 ms per frame re-deriving colors that had not changed, against a 16 ms budget
for 60fps. It was the app's single largest source of lag, and it was nowhere
near the search code where reading it would have pointed first.

`ResolvedPalette` computes them once, when the theme changes. Nothing about the
resulting colors changed - `paletteAudit` compares 768 resolved colors across 12
themes against the same themes computed the old way, and breaking one on purpose
fails it.

`ThemeManager.theme` is memoised for the same reason: it was rebuilding the whole
theme per access, which for a custom theme meant a store lookup and eleven hex
parses every time any view asked what color anything was.

## Contrast is a gate, not advice

`ThemeRules` and `Contrast` are not styling helpers. A theme cannot be used
until it passes an audit of 43 pairings, and `ThemeDoctor` repairs what fails.
This exists because a palette that is beautiful on a marketing page is regularly
unreadable in a dense list, and "the user can pick a bad theme" is not an
acceptable answer when the app is offering to generate themes from arbitrary
design documents.

Two things the audit learned by being wrong:

- **Composite before measuring.** It used to grade `white.opacity(0.45)` as pure
  white, which made every theme score better than it rendered.
- **A status color needs every ground it lands on.** Delete sits on the card,
  the hovered row and the selected row. Derived against the card alone it failed
  on the other two in every preset.

## Sync

One protocol, entity-agnostic: `/sync` takes any `entity` string, which is how
settings sync exists without a server change. Records carry `updatedAt`, deletes
carry tombstones, and the watermark moves before the work rather than after.

Anything that points at a path on this Mac - images, video, files, folders,
via `ClipboardItem.isLocalOnly` - never crosses this protocol at all: the path
is only meaningful here, so it stays here. Only text-like clips sync.

Three methods, mutually exclusive, and the exclusivity is enforced where it
matters rather than in the UI:

- **Google** goes to the project's own service. `ServiceKind` is persisted and
  set before the first request of each flow, so the two methods can never share
  an address. They did once: `baseURL` was a single preference, so signing in
  with Google sent your clipboard to whatever was typed in the Server field.
- **Token** goes to a server you run. Anonymous - the token *is* the account.
- **Export/import** touches no server at all.

The server takes the space id **from the token, never from the request body**.
That single line is the difference between a sync service and a data breach.

## The QA bridge

`Core/QABridge.swift` is a file-driven harness: a command file in, a state file
out. It exists because behaviour should be *proved* rather than eyeballed, and
because SwiftUI is difficult to test any other way.

It is compiled out unless `CLIP_TESTING` is defined; both the `Debug` and `Testing`
build configurations define it (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` is
`DEBUG CLIP_TESTING` for Debug, `CLIP_TESTING` for Testing) - only `Release` omits
it, and `package.sh` independently verifies the symbol is absent from the packaged
binary before allowing a DMG build. It reads commands from disk and writes the
entire clipboard history back out, so in a shipped app it would be a remote
control, and gating it on an environment variable is not a boundary when whoever
starts the process controls the environment.

## Things that will bite you

Collected because each one cost real time.

- **`@AppStorage` caches.** Writing `UserDefaults` underneath it leaves the
  running app reading the old value. This is why applying a settings snapshot
  from another Mac wrote the right thing to disk and changed nothing you could
  see, until a relaunch. `PreferencesModel.reloadFromDefaults()` exists for that.
- **`NWListener` publishes its port only after reaching `.ready`**, which is
  asynchronous and therefore useless when you need the port to build a redirect
  URI. `LoopbackListener` uses raw BSD sockets and `getsockname` instead.
- **`NSWindow.setFrame(display:animate:)` is synchronous and pumps the run
  loop**, so a timer can fire inside it and re-enter your resize.
- **`UTType(exportedAs:)` traps at runtime** unless the type is declared in
  `Info.plist` under `UTExportedTypeDeclarations`.
- **A Swift dictionary literal with a duplicate key crashes at launch**, which
  is why the probe checks the state dictionary for duplicates before anything
  else runs.
- **`resident_size` is not your app's memory.** It counts shared framework pages
  and reported 223 MB for an app whose real footprint was 33.8 MB. Use
  `phys_footprint`.
- **An ad-hoc signature changes on every build**, so macOS re-prompts for
  Keychain access after every update - and an agent app with no window has
  nowhere to show that prompt, so it simply hangs. This is why
  `ServerConfig.load()` no longer touches the Keychain.
