# Clip copywriting guide

The single source for how Clip talks. Every string in the app, from a button
label to a security paragraph, is written by one voice. This guide exists so
any writer, developer, or agent produces that same voice without having to
guess. Built from a full inventory of the app's roughly 1,290 user-facing
strings; every rule below traces back to a real inconsistency that inventory
found, or a real string worth keeping as the model.

American spelling throughout, including this document. No em dash. No arrow
characters, in UI copy or in this guide itself; keyboard hints are described
in words instead (see Section 4).

---

## 1. Clip in one line, and who we talk to

**Clip remembers everything you copy, works out what kind of thing it is, and
keeps it ready to use again.** That is the whole promise. Not "AI-powered
productivity," not "supercharge your workflow." A clipboard manager that pays
attention, and a small library of the text you reuse.

**Audience:** consumers, not IT departments. Ages 12 to 60. Every gender.
Every country, so no idiom, no US-only reference, no assumption about time
zone or measurement system. Laptop use only, keyboard-first, on macOS.
Technical and non-technical users side by side, in the same app, reading the
same strings.

**Made concrete:** a 12-year-old student and a 60-year-old accountant open the
same error message. Neither gets a dumbed-down version and neither gets a
version with jargon the other one lacks. They get one plain sentence, written
at a reading level a middle schooler manages comfortably, and a curious adult
never feels talked down to by. A developer and a non-technical user open the
same "Server" settings page. The non-technical user reads "the link to the
folder on your web space where you put Clip's files, the same kind of link
you would type into a browser" and knows what to paste. The developer reads
the same sentence and also gets the exact fact they need, "the answer is the
word localhost," because the precise term was folded in right where it
mattered, not hidden behind a details toggle only they can find. One string.
Two readers. Neither one gets a lesser version.

This is the standard for every string in this document: never write two
versions of the same message for two audiences. Write the one sentence that
serves both.

---

## 2. Voice: five traits

"Cool" means calm, confident, quick, a little playful when the moment allows
it, and never trying hard. Never slang that will sound dated in a year.
Never corporate. Five traits carry that:

### Calm

Never alarmist. No shouting in punctuation or capitals. A serious moment
gets a serious sentence, not a louder one.

| | |
|---|---|
| Do | State what happened and what to do about it, at normal volume. |
| Don't | Capitalize a word for emphasis ("NOT granted," "database NOT open," "MOVES them"). |

**Before** (`DiagnosticsInsights.swift:53-56`): "NOT granted. Clip cannot
paste until this is granted."
**After:** "Not granted yet. Clip can't paste until you turn this on."
**Rule applied:** no caps-for-emphasis; word order and a plain contraction
carry the weight instead.

### Direct

Lead with the verb. Say what happens, not what happens "instead of" some
other thing.

| | |
|---|---|
| Do | "Turn an action off and it disappears from the menu instead of sitting there grayed out." |
| Don't | Bury the actual behavior in a comparison clause: "Anything off is absent from the menu rather than greyed out in it." |

**Before** (`SettingsPasteActionsPane.swift:275`): "Anything off is absent
from the menu rather than greyed out in it."
**After:** "Turn an action off and it disappears from the menu instead of
sitting there grayed out."
**Rule applied:** verb first, active voice, American spelling.

### Confident

State facts plainly. Cut hedging and repetition. Trust the reader to follow
one clean sentence.

| | |
|---|---|
| Do | "Any address works, no special name required." |
| Don't | Restate the same idea twice to sound thorough: "Any address works, it does not need a special name." |

**Before** (`SettingsSyncPane.swift:1229`): "The web address Clip talks to:
the link to the folder on your web space where you put Clip's files, the
same kind of link you would type into a browser. Any address works, it does
not need a special name."
**After:** "The address Clip talks to: the link to the folder on your web
host where you put Clip's files, the kind you would type into a browser. Any
address works, no special name required."
**Rule applied:** state it once, plainly, and stop.

### Quietly playful, never in the wrong room

A little personality is welcome in low-stakes moments: empty states, success
toasts, idle placeholders. Errors, security, sync, and anything destructive
stay completely straight. No jokes at the door when something has gone wrong.

| | |
|---|---|
| Do | Let an empty state be warm: "Nothing here yet, click to add something." |
| Don't | Bring that same warmth into an error, a security notice, or a delete confirmation. |

**Before** (`CollectionViews.swift:336`): "Empty, click to edit"
**After:** "Nothing here yet, click to add something."
**Rule applied:** low-stakes moments can be a little warm; high-stakes ones
never are.

### Respectful of the reader's intelligence

Plain language first, always. The precise technical term follows, right
there, when it is the actual thing the reader needs, never as filler to sound
expert.

| | |
|---|---|
| Do | "Type it in myself (the exact model ID)." |
| Don't | Force a reader to already know the jargon before the sentence makes sense: "Enter a model id myself." |

**Before** (`SettingsAIPane.swift:458`): "Enter a model id myself"
**After:** "Type it in myself (the exact model ID)"
**Rule applied:** plain phrase first, precise term in parentheses when it is
the thing the user must actually type.

---

## 3. Tone dial per surface

Voice stays constant. Tone, how that voice sounds in a given moment, shifts
with the surface and the stakes.

| Surface | What the copy must do | Reference |
|---|---|---|
| Onboarding | Teach and invite. Four short steps, in the order the app actually needs them: permission first, then AI, then tabs, then sync. See Section 5. | `OnboardingView.swift`, `SetupChecklist.swift` |
| Everyday UI (labels, tabs, buttons) | Quiet and functional. Sentence case for labels, Title Case only for buttons, menu items, and tab names. | Section 4 |
| Tooltips and help | One sentence, states what the control does or why it exists. Ends without a period unless there are two sentences. | `.help()` strings across the app, e.g. `CollectionViews.swift:139` |
| Empty states | Say why it's empty, what will appear here, and one thing to do about it. Distinguish first-use ("nothing copied yet") from user-cleared from no-search-results; never present them the same way. | `GalleryView.swift:121-125` |
| Success and progress | State what is now true, in specifics. Never a bare "Success!" | `SettingsExportPane.swift:427-429`, `"Restored 12 items."`-style strings |
| Errors | What happened, then what to do. No blame ("invalid," "illegal," "you failed"). No jargon unless the jargon is the actual fix. | Section on errors below, and the `AIDiagnosis.swift` message/remedy pattern |
| Destructive confirmations | Plain and specific. The button names the exact action ("Delete," "Clear Everything," "Disconnect"), never a generic "OK" or "Yes." Title is a direct question naming what is removed; body says what happens and what survives. | `SettingsView.swift:267-279`, `SettingsThemePane.swift:146-150` |
| Security, privacy, and sync | Calm precision. Say exactly what is and is not sent or stored. The two sentences below are locked and appear verbatim wherever this topic is shown. | `docs/USER-FACING-COPY.md` |
| AI features | Honest about what the model does. Name the actual action (translate, rewrite, summarize). Never call it magic, smart, or intelligent. State plainly that it only runs when invoked, and that keys live in the Keychain, never uploaded. | `SettingsAIPane.swift:111-117`, README's "the AI happens on the way out" |
| Menu bar and notifications | Shortest possible copy. Front-load the meaning in the first few words, since a notification preview can truncate. | `NoticeBar.swift`, `AppDelegate.swift:577-594` |
| Updates | Say what changed, in the reader's language, never a commit log. | `appcast.xml`'s own commented guidance, quoted in Section 5 |

### Security, privacy, and sync: the two locked sentences

These are argued at length elsewhere and never reworded. They are the model
for every other sentence on this topic, calm, specific, no hedging, no
hype:

> Clipboard contents are stored unencrypted on this Mac. A key this app could
> use on its own is a key anyone with the same file access could use too, so
> encrypting here would not add real protection, what protects this data is
> FileVault, which is already on your Mac if you turned it on at setup.

> Sync carries text only. Images, files and folder references stay on the
> Mac that captured them, because a file path only means something on that
> Mac.

(Reproduced here with the source document's own hyphen-as-clause-break kept
intact per the "argued in full elsewhere, do not reword" rule in
`USER-FACING-COPY.md`; new sentences on this topic should use a period
instead, per Section 4's punctuation rule.)

### Errors, in full

Every error follows the same shape: **what happened**, in one precise
sentence, never "an error occurred"; then **what to do**, a concrete next
step, in the same sentence or the one after it. Never blame the user. Never
surface a raw error code as the headline, a code can sit in fine print, the
human sentence leads. Preserve whatever the user typed so they can fix it,
never make them start over.

### Destructive confirmations, in full

Two subtypes exist, and both stay:

1. **Everyday destructive confirm** (delete a theme, clear history, forget a
   token): title is a plain question naming what is removed
   ("Delete this theme?"), body states what happens and what survives, the
   button repeats the exact verb from the title.
2. **System-permission preview** (`CredentialExplainer.swift`): a longer
   three-part structure because the stakes are trust in the system prompt
   about to appear, not data loss. Keep the structure. Tighten the opening
   line's register, see Before/After row 26 in Section 9.

---

## 4. Micro-copy rules

**Buttons.** Verb first. Title Case. One to three words. The label says what
happens, not the current state ("Pause," never "Playing"). Destructive
buttons name the destructive verb directly ("Delete," "Clear Everything"),
never "Confirm" or "OK."

**Labels.** Sentence case. Noun phrases ("Data location," "Sync token"), not
questions or instructions.

**Toggles.** State what turns on, in the reader's terms, not the internal
flag name. "Launch at login," not "Enable login item."

**Placeholders.** An example or a hint, never a repeat of the visible label,
and never a bare status word like "Optional." If a field is optional, say so
in the label, and use the placeholder for an example value.

- Before (`ColorComposer.swift:66`): placeholder "Optional"
- After: placeholder "e.g. Sunset Orange"

**Tooltips.** One sentence. Ends without a period. Two sentences, both get
periods. Names the control it belongs to when that isn't obvious from
context.

**Counts and plurals.** Always branch singular and plural, even for a count
that is rarely one. "1 revisions" and "1 items" read broken to every kind of
reader, technical or not.

- Before (`BackupArchive.swift:475`): `"\(versionsRestored) revisions"`
  (never singularizes)
- After: `"\(versionsRestored) revision\(versionsRestored == 1 ? "" : "s")"`
- Before (`AIService.swift:611`): `"Composed from \(pieces.count) items"`
- After: `"Composed from \(pieces.count) item\(pieces.count == 1 ? "" : "s")"`

**Time and dates.** Relative when recent ("2 minutes ago," "yesterday"),
an unambiguous absolute date otherwise (a spelled month, "Aug 30," never
"8/30" or "30/8," both of which read as a different date depending on the
reader's country).

**Numbers and units.** Spell out the unit in a full sentence; a bare symbol
reads ambiguous out of context.

- Before (`ListView.swift:154`): `"used \(item.useCount)×"`
- After: `"used \(item.useCount) times"`

A compact badge with real space constraints may keep a symbol, but only when
a tooltip spells the same value out in words for anyone who needs it.

**Keyboard shortcuts.** In the UI itself, use the system's own symbols for
Command, Shift, Option, and Control. In prose, spell the combination out:
"press Command-Shift-Space," never the glyphs strung together in a
sentence. The panel's own hint footer
uses the system's arrow-key, return, and escape glyphs for movement, confirm,
and cancel; when describing those same actions in a sentence, spell them out
as "the arrow keys," "press Return," and "press Escape" rather than
reproducing the glyphs.

**Truncation and length budgets.** Targets to design against, verify each
against the actual rendered control before shipping:

| Control | Target |
|---|---|
| Button | 1 to 3 words |
| Tab / section header | 1 word, 2 at most |
| Tooltip | one sentence, aim under about 80 characters |
| Toast / menu-bar banner | one line, aim under about 60 characters so it doesn't wrap in a preview |
| Settings page hero help | one sentence |
| Empty-state subtitle | one sentence, one action named |

**Capitalization.** Title Case for buttons, menu items, and tab names.
Sentence case for everything else: labels, section headers, toggles, help
text, alert titles.

- Before (`OnboardingView.swift:154`): "SET UP IN FOUR STEPS"
- After: "Set up in four steps"
- Before (`CredentialExplainer.swift:141`): button "Not now"
- After: button "Not Now" (matches `OnboardingView.swift:270`'s own "Not
  Now," one button, one casing)

**Punctuation.**
- No em dash. Use a comma, a colon, or a period instead.
- No arrow characters, spell the relationship out or use a colon.
- No exclamation point, with one possible exception: a single welcome
  headline at first launch, if the product ever wants one. Today's inventory
  has zero exclamation marks anywhere in the app; keep it that way outside
  that one moment.
- No ellipsis except the single Unicode "…" character, and only on a control
  that opens another step or takes time to complete ("Export Settings…",
  "Testing…").
- A mid-sentence break uses a comma or starts a new sentence with a period,
  never a hyphen doing the work of a comma or a colon.

  - Before (`PasteTransform.swift:148`): "Ready - press ⌘V"
  - After: "Ready. Press ⌘V."

- Quote UI labels, typed values, or referenced phrases with curly quotes
  ("like this"), never straight quotes, and never nested inside a title.

  - Before (`PasteActions.swift:266`): `"There is already an action called "\(name)"."` (straight quotes)
  - After: `"There is already an action called "\(name)"."` (curly quotes, matching the existing correct model at `ShortcutRegistry.swift:180`)

**Emoji.** None in UI. Ever. Icons carry visual meaning; text carries text.

---

## 5. Macro copy

### Onboarding narrative arc

Four steps, always in this order, because each one unlocks the next:

1. **Permission to paste.** Nothing else works without Accessibility, so it
   comes first and explains the cost of skipping it plainly: "Decline it and
   pasting stops, silently."
2. **Connect an AI model.** The single highest-leverage feature, introduced
   before habits form around the plain clipboard alone.
3. **Customize your tabs.** Make the app match how the reader already works,
   once they've seen what it can do.
4. **Sync your account.** Extending the library across machines, last,
   because it's optional and needs either an account or a token, the
   highest-commitment step of the four.

The AI step in `SetupChecklist.swift:85-95` is currently a dense run-on
sentence naming nearly every paste action by name, while the other three
steps are two or three short sentences. Bring it in line: one short lead
sentence on the outcome ("Connect a model, and Clip can rewrite, translate,
or summarize what you copy"), then at most a few named examples, not a full
enumeration that has to be kept in sync with the actual action list by hand.

### Settings page intros

One sentence, stating what the page lets the reader do, not what it
contains. The existing hero lines already do this well and are the model to
match everywhere:

| Page | Intro |
|---|---|
| Sync | "Combine this Mac's clipboard history with your other Macs over a token, so a copy on one shows up on the rest." |
| AI | "Let Clip rewrite, translate, or summarize what you copy, using a connection you provide." |
| Diagnostics | "Check Clip's own health, and fix what it can fix itself." |
| Themes | "Choose how Clip looks, or build a theme of your own." |
| Menu Bar | "How Clip shows itself outside its own window: the icon, the copy confirmation, and where the panel opens." |

### Help and explanatory paragraphs

Lead with the outcome, then the mechanism. "Combine this Mac's clipboard
history with your other Macs over a token" (the outcome) comes before "so a
copy on one shows up on the rest" (the mechanism). Never the reverse.

### Release notes voice

The app's own commented-out template already states the rule precisely:
"What changed, in the user's language, not the commit log." The currently
committed `appcast.xml` entry ("See the release notes for what changed") is a
placeholder, not real customer-facing prose; **this string must be verified
and replaced with real release notes before shipping an update**, per the
constraint against inventing product facts.

---

## 6. Vocabulary

### Canonical terms

| Concept | We say | We never say |
|---|---|---|
| Anything the reader has saved, of any of the five kinds | item | entry, thing, object |
| Specifically a plain clipboard capture (the default kind, not a Prompt/Note/Skill/Design) | clip | item, when the distinction from the other four kinds actually matters |
| Marking something to keep at the top | pin (verb), pinned (adjective) | favorite, star, bookmark |
| One of the sections inside the panel (All, Prompts, Notes, Skills, Designs, and the type filters) | tab | view, category, section |
| The floating window opened with the global shortcut | panel | window, popup, HUD |
| The separate preferences interface | Settings | preferences, options, config |
| A quick text transform run on what's about to be pasted | paste action | transform, AI action, macro |
| The long string that links two Macs without an account | sync token | key, code, auth token |
| A saved look for the app (colors, fonts, radius) | theme | skin, style pack |
| Everything saved across every tab | library | collection, database, store |
| The chronological record inside the Clips tab specifically | history | log, feed |
| Navigating to a specific settings page | "Settings > AI" (with spaces around the angle bracket) | "Settings, AI", "in Settings" alone when a specific page is meant |

Fixes this resolves directly from the inventory:

- `KeyRecovery.swift:210-211, 221-223` and `CredentialExplainer.swift` use
  "Settings, AI"; standardize to "Settings > AI" everywhere, matching the
  correct existing usage at `NoticeBar.swift:80` and `SettingsAIPane.swift`'s
  own section title.
- `SettingsExportPane.swift:642-649` uses "entr(y/ies)" for what every other
  surface calls an item; replace with "item(s)."
- `ItemKind.swift:66-77` badges the `.url` kind "URL" while its own
  `displayName` and every filter chip call it "Link." One name per concept:
  the badge should read "LINK."

### Banned list

AI tells (never use these in Clip's copy):

delve, seamless, leverage, empower, robust, unlock, elevate, supercharge,
effortless, simply, just (as a minimizer), please note, in order to (say
"to"), streamline, foster, cultivate, garner, harness, utilize, groundbreaking,
cutting-edge, innovative, transformative, holistic, comprehensive, pivotal,
dynamic, paradigm, synergy, landscape, ecosystem, game-changer, deep dive,
pain point, north star, significantly, remarkably, meticulously, truly,
genuinely, craft (as a verb for writing).

Corporate filler and hype: "best-in-class," "world-class," "cutting the
noise," "at scale," "unlock your potential," "game-changing," "revolutionize."

Jargon without a plain alternative available: banned outright. Jargon that
is the actual, necessary fact the reader needs (a model ID, "localhost," an
HTTP status code in a support-facing report) stays, plain-first, per Section
7.

---

## 7. Technical and non-technical together

The pattern: a plain sentence stating the outcome, then the precise term
folded in right where it matters, in parentheses or the very next clause,
never hidden behind a separate "Details" toggle unless the explanation is
genuinely long.

1. **`SettingsSyncPane.swift:1232`**: "Where the database lives, as seen
   from the server. On almost every web host it's the same machine as the
   site, so the answer is the word localhost." Plain first ("the same
   machine as the site"), precise term kept because it is the literal value
   to type.
2. **`SettingsAIPane.swift:458`**: "Type it in myself (the exact model ID)."
   Plain verb first, the technical term in parentheses because it is exactly
   what has to be typed.
3. **`AIDiagnosis.swift:97`**: "That's more text than this model can read at
   once. It comes to about 300 tokens (roughly 1,200 characters)." Plain
   statement first, technical measure (tokens) folded in with a plain unit
   (characters) right alongside it.
4. **`SettingsSyncPane.swift:1250`**: "A token is a key. Over plain HTTP
   anyone on the network can read it in transit." Plain analogy first (a
   key), the technical fact (HTTP) stated exactly because the fix is a
   literal toggle labeled "Require HTTPS."
5. **`SettingsSyncPane.swift:1310-1313`**: "Clip writes the files to upload,
   the SQL that builds the tables, and the steps, filled in with what you
   entered. Any host running PHP 8 and MySQL will do." Plain outcome first
   (Clip writes it for you), exact technical requirement stated precisely
   (PHP 8, MySQL) because it is the actual fact a self-hosting reader must
   check before starting.

---

## 8. Inclusive and global

- No gendered words. No "guys," no gendered pronoun assumptions anywhere a
  reader isn't named.
- No idiom, no regional metaphor ("ballpark," "home run," "low-hanging
  fruit"). Say the literal thing.
- No cultural or national reference (a holiday, a sports season, a national
  event) as a timing anchor or example.
- Dates are unambiguous: a spelled month plus day ("Aug 30"), never a
  numeric date format that reads differently in different countries.
- Works for a 12-year-old: short sentences, no slang that ages, no assumed
  familiarity with corporate or developer culture.
- Works for a 60-year-old: no gamer slang, no meme-speak, nothing that
  assumes recent internet culture as shared context.
- Works for a developer and a non-technical reader in the same sentence, per
  Section 7's pattern.

---

## 9. Before / After

Forty real strings from the inventory, chosen to cover every surface and
every voice trait. These are the reference set for the rewrite.

| # | File:line | Before | After | Rule applied |
|---|---|---|---|---|
| 1 | `SettingsView.swift:52-53` | "Follows System [em dash] light in Light Mode, dark in Dark Mode" | "Follows System: light in Light Mode, dark in Dark Mode" | No em dash; use a colon. |
| 2 | `ModelCatalog.swift:18` | `"\(title) [em dash] \(note)"` | `"\(title) (\(note))"` | No em dash; matches the parenthetical pattern already used by `AIProvider.swift`. |
| 3 | `SettingsShell.swift:298` | "Behaviour" | "Behavior" | American spelling only. |
| 4 | `SettingsSyncPane.swift:860-863` | "dragging a colour slider" | "dragging a color slider" | American spelling only. |
| 5 | `SettingsPasteActionsPane.swift:275` | "Anything off is absent from the menu rather than greyed out in it." | "Turn an action off and it disappears from the menu instead of sitting there grayed out." | American spelling; verb-first, direct phrasing. |
| 6 | `PanelMetrics.swift:155-162` | "Centre of the screen" | "Center of the screen" | American spelling only. |
| 7 | `PasteActions.swift:64-81` | "Summarise" | "Summarize" | American spelling only, matches `SetupChecklist.swift`'s own usage. |
| 8 | `OnboardingView.swift:154` | "SET UP IN FOUR STEPS" | "Set up in four steps" | Sentence case for section headers, never all caps. |
| 9 | `OnboardingView.swift:221` | "RESTORE FROM SYNC" | "Restore from sync" | Sentence case for section headers. |
| 10 | `CredentialExplainer.swift:141` | button "Not now" | button "Not Now" | Title Case for every button, one casing for one action across the app. |
| 11 | `SettingsPrivacyPane.swift:302-307` | "Reclaiming MOVES them into a dated folder inside Clip's own data folder" | "Reclaiming moves them into a dated folder inside Clip's own data folder" | No caps-for-emphasis. |
| 12 | `SettingsPrivacyPane.swift:382` | "Sync is ON: your content is uploaded to \(destination) under your account." | "Sync is on. Your content is uploaded to \(destination) under your account." | No caps-for-emphasis; two calm sentences. |
| 13 | `StorageDiagnosis.swift:74-75` | "\(unreadable) of \(total) items could not be read and were NOT deleted." | "\(unreadable) of \(total) items could not be read. They were not deleted." | No caps-for-emphasis. |
| 14 | `DiagnosticsInsights.swift:53-56` | "NOT granted. Clip cannot paste until this is granted." | "Not granted yet. Clip can't paste until you turn this on." | No caps-for-emphasis; contraction keeps it conversational. |
| 15 | `DiagnosticsInsights.swift:250` | "database NOT open - Clip cannot read or save clips until it is." | "Database not open. Clip can't read or save clips until it is." | No caps-for-emphasis; hyphen-as-clause-break replaced with a period. |
| 16 | `SettingsSyncPane.swift:388-391` | "Removes the saved token from THIS Mac's Keychain." | "Removes the saved token from this Mac's Keychain." | No caps-for-emphasis; "this Mac" already carries the distinction. |
| 17 | `ItemKind.swift:66-77` | badge "URL" (displayName "Link") | badge "LINK" | One name per concept, badge matches its own display name. |
| 18 | `ListView.swift:154` | `"used \(item.useCount)×"` | `"used \(item.useCount) times"` | Spell out the unit; a bare symbol reads ambiguous out of context. |
| 19 | `KeyRecovery.swift:210-211` | "You can do this later from Settings, AI." | "You can do this later from Settings > AI." | One notation for navigation, never a comma. |
| 20 | `SettingsSyncPane.swift:1512` | "open Settings, then Sync, then paste it under..." | "open Settings > Sync, then paste it under..." | One notation for navigation throughout the app. |
| 21 | `SettingsExportPane.swift:352-358` | "Items you already have are matched by id and replaced only when the file's copy is newer" | "Items you already have are recognized automatically and replaced only when the file's copy is newer" | Cut jargon that doesn't help the reader act; keep the plain outcome. |
| 22 | `SettingsAIPane.swift:458` | "Enter a model id myself" | "Type it in myself (the exact model ID)" | Plain phrase first, precise term in parentheses when it's the thing to type. |
| 23 | `SettingsAIPane.swift:389-391` | "you should not have to type a model id" | "you shouldn't have to type a model ID yourself" | Contractions read more direct and conversational. |
| 24 | `AIDiagnosis.swift:97` | "That is more text than this model can read at once. This text is about \(n) tokens (\(chars) characters)." | "That's more text than this model can read at once. It comes to about \(n) tokens (roughly \(chars) characters)." | Plain statement first, technical measure folded in with a plain unit. |
| 25 | `SettingsSyncPane.swift:1232` | "the answer is the word localhost" | "so the answer is the word localhost" (tightened lead-in: "On almost every web host it's the same machine as the site") | Plain first, precise technical value kept because it's the literal fix. |
| 26 | `CredentialExplainer.swift:50-62` | "What will be asked: macOS may show its own password prompt so Clip can re-read the API keys..." | "What happens: macOS may ask for your password so Clip can re-read the API keys..." | "What happens" reads the same to a 12-year-old and a developer; "what will be asked" is stiff, procedural phrasing. |
| 27 | `TypeEditors.swift:163-165` | "...but \(n) color pairing\(s) could not be made readable - this palette was built for a page, not a dense list." | "...but \(n) color pairing\(s) couldn't be made readable. This palette was built for a page, not a dense list." | Hyphen-as-clause-break replaced with a period; contraction. |
| 28 | `PasteTransform.swift:148` | "Ready - press ⌘V" | "Ready. Press ⌘V." | Hyphen-as-clause-break replaced with a period. |
| 29 | `ColorComposer.swift:104-106` | "Nothing on the clipboard" / "The clipboard does not hold a color" | "There's nothing on the clipboard right now." / "The clipboard doesn't hold a color Clip can read." | Blameless and specific; contractions keep the tone conversational. |
| 30 | `TypeEditors.swift:154` | "This document does not carry a color palette." | "This document doesn't have a color palette in it." | Plain phrasing over formal "does not carry"; contraction. |
| 31 | `ShortcutRecorder.swift:132` | "That key cannot be recorded" | "That key can't be recorded" | Contractions throughout error copy, quicker and warmer. |
| 32 | `SettingsExportPane.swift:589` | "...none of them look like a design document (a folder named for a brand, containing DESIGN.md)." | "...none of them look like a design document, a folder named for a brand that contains a DESIGN.md file." | Fold the parenthetical into the sentence for a smoother, less manual-like read. |
| 33 | `SettingsExportPane.swift:642-649` | `"\(unreadable) entr\(unreadable == 1 ? "y" : "ies") could not be read."` | `"\(unreadable) item\(unreadable == 1 ? "" : "s") couldn't be read."` | Canonical noun is "item," never "entry," for anything in the library. |
| 34 | `BackupArchive.swift:475` | `"\(versionsRestored) revisions"` (never singularizes) | `"\(versionsRestored) revision\(versionsRestored == 1 ? "" : "s")"` | Always branch singular and plural. |
| 35 | `AIService.swift:611` | `"Composed from \(pieces.count) items"` | `"Composed from \(pieces.count) item\(pieces.count == 1 ? "" : "s")"` | Always branch singular and plural. |
| 36 | `AIProvider.swift:851-855` | "OpenAI (ChatGPT)" beside "Anthropic (Claude)" | **Must be verified with the product owner**: should this read "OpenAI (API)" to match the brand+product pattern beside it, or is naming ChatGPT intentional because it's the name most readers recognize? | Flag, don't invent, when the correct fact is a product decision, not a copy decision. |
| 37 | `ColorComposer.swift:66` | placeholder "Optional" | placeholder "e.g. Sunset Orange" | Placeholders show an example, never a bare status word; mark "optional" in the label instead. |
| 38 | `SettingsPasteActionsPane.swift:347` | `"Styles in "Rewrite in a style""` (a quoted feature name nested inside a title) | `"Styles for Rewrite in a Style"` | Reference a feature name in Title Case, never nested quote marks inside a title. |
| 39 | `SettingsSyncPane.swift:1041-1044` | "so it will not work here" | "so it won't work here" | Contractions throughout, consistent with "quick, never trying hard." |
| 40 | `PasteActions.swift:266` | `"There is already an action called "\(name)"."` (straight quotes) | `"There is already an action called "\(name)"."` (curly quotes) | One quoting style app-wide, matching the correct existing model at `ShortcutRegistry.swift:180`. |

---

## 10. Checklist for any new string

1. Does it say what happens, not just that something happened?
2. Is it the shortest version that still does the job?
3. Would a 12-year-old and a 60-year-old both understand it on first read?
4. If it names something technical, is the plain meaning stated first?
5. Is it blameless, no "invalid," "illegal," "you failed," or similar?
6. Does it use the canonical term from Section 6, not a synonym?
7. Is capitalization correct for its type (Title Case for buttons/menus/tabs,
   sentence case for everything else)?
8. No em dash, no arrow character, no all-caps for emphasis, no exclamation
   point outside the one welcome exception?
9. Does every count correctly branch singular and plural?
10. Would this same string work for a non-technical user and a developer,
    with no second version needed?
