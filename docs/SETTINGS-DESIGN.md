---
name: Clip Settings Design Language
description: Clip's own Settings window redrawn in Apple's own grammar - grouped rounded cards on a dark ground, a hero header per pane, chevron drill-down, and sentence-case verbs for copy - learned from 31 screenshots of macOS Tahoe 26.5.2 System Settings and mapped onto Clip's existing Graphite tokens rather than a new palette.
source:
  screenshots: "macOS Tahoe 26.5.2, System Settings, dark appearance, retina (2x), 31 frames, image-cache 17.png-47.png"
  codebase:
    - Clip/Theme/AppTheme.swift (Graphite preset, the settings window's actual theme)
    - Clip/Theme/Spacing.swift (4pt ladder)
    - Clip/Theme/Typography.swift (named type roles)
    - Clip/Views/SettingsShell.swift (NavigationSplitView shell, search field, sync row)
    - Clip/Views/SettingsPalette.swift (note/danger/success/warning text colors, hover wash)
    - Clip/Views/Settings*Pane.swift (11 tabs' current rows)
  note: "Every numeric value below is either (a) pixel-measured from a cited screenshot at 2x, divided by 2 for logical pt, or (b) an existing constant read from the cited Swift file, or (c) marked HIG where it is a documented Apple Human Interface Guidelines value rather than a pixel count. Nothing is guessed."

color:
  # --- Apple's measured palette (source system; Clip does NOT switch to these) ---
  apple:
    ground: "#1F212D"          # page background behind cards, measured screenshot18.png (RGB 31,33,45)
    card: "#272934"            # card/row fill, measured screenshot18.png (RGB 39,41,52)
    divider: "#31333E"         # hairline between rows inside a card, measured screenshot18.png (RGB 49,51,62)
    sidebarSelected: "#2557CA" # selected sidebar row fill, measured screenshot17.png (RGB 37,87,202)
    toggleOn: "#397CF6"        # Wi-Fi toggle "on" track, measured screenshot19.png (RGB 57,124,246)
    link: "#5A9AF8"            # "Learn More..." / "About Search & Privacy..." link text, measured screenshot19.png (RGB 90,154,248)
    iconTileGray: "#8E8E93"    # the neutral-gray glyph tile behind a hero/system icon, measured screenshot17.png - the tile is not a flat fill (it has a subtle top-to-bottom gradient from near-white to mid-gray); this hex matches its darker lower band, sampled around RGB(142,142,148)
    statusGreen: "#68CE67"     # "Connected" dot, pixel-sampled screenshot21.png (Wi-Fi row) - solid fill (104,206,103); notably lighter/more saturated than the textbook HIG systemGreen(dark) swatch #34C759 (52,199,89), most likely a Display P3-to-sRGB byte shift in the capture rather than a different authored color - use this measured value, not the textbook one
    statusRed: "#EB534E"       # "Not Connected" dot, pixel-sampled screenshot21.png (USB LAN row) - solid fill (235,83,78); the textbook HIG systemRed(dark) swatch is #FF453A (255,69,58) - same hue family, measurably less saturated in the actual capture
    statusGray: "#5D5E66"      # "Inactive" dot, pixel-sampled screenshot21.png (Firewall row) - solid fill (93,94,102); darker than the textbook HIG systemGray swatch #8E8E93 (142,142,147) - do not reuse iconTileGray's hex for this dot, they read differently on screen
    warningTriangle: "#F8D849" # Privacy Warning triangle, pixel-sampled screenshot19.png - solid fill (248,216,73); the textbook HIG systemYellow(dark) swatch is #FFD60A (255,214,10), noticeably more blue/less saturated here
    textPrimary: "#FFFFFF"     # row labels and hero title, screenshot17.png/18.png
    textSecondary: "not isolated as a flat swatch; visually ~68% white (NSColor.secondaryLabelColor, HIG default)"

  # --- Clip's adopted tokens (Graphite preset already in AppTheme.swift; unchanged by this doc) ---
  panel: "#1A1C1F"             # {AppTheme.presets[graphite].panelBackground}, RGB 0.10/0.11/0.12
  card: "#292B2E"              # {AppTheme.presets[graphite].cardBackground}
  cardHover: "#333638"         # {AppTheme.presets[graphite].cardHoverBackground}
  selected: "#0D66D9"          # {AppTheme.presets[graphite].selectedBackground}
  surface: "#212426"           # {AppTheme.presets[graphite].surfaceBackground}
  border: "#303436"            # {AppTheme.presets[graphite].border}
  accent: "#0A6EF4"            # {AppTheme.presets[graphite].accent}
  accentSecondary: "#00B8E6"   # {AppTheme.presets[graphite].accentSecondary}
  textPrimary: "#FFFFFF"       # {AppTheme.presets[graphite].textPrimary}
  textSecondary: "#C3C4C5"     # {AppTheme.presets[graphite].textSecondary}
  textTertiary: "#949697"      # {AppTheme.presets[graphite].textTertiary}
  note: "adaptive(#595959 light / #A9A9A9 dark)"     # {SettingsPalette.note}
  danger: "adaptive(#C4271F light / #FF6B6E dark)"   # {SettingsPalette.danger}
  success: "adaptive(#1B7A38 light / #3FD46A dark)"  # {SettingsPalette.success}
  warning: "adaptive(#8A5200 light / #FFA93D dark)"  # {SettingsPalette.warning}
  hover: "Color.primary at 7% opacity"               # {SettingsPalette.hover}
  # --- New roles this doc adds, because Apple's pattern needs them and Clip's settings did not name them yet ---
  divider: "{color.border} at 60% opacity"           # new role: row divider inside a grouped card (Apple pattern, section 4)
  statusConnected: "{color.success}"                 # new role: green status dot (Apple pattern, section 4/5)
  statusDisconnected: "{color.danger}"                # new role: red status dot
  statusInactive: "{color.textTertiary}"             # new role: gray status dot
  link: "{color.accent}"                              # new role: inline text link ("Learn more...")

type:
  # Clip's existing named scale (Typography.swift) - unchanged, reused for Settings.
  heading: "15pt semibold"        # {Typography.heading} - a pane's own hero title candidate
  subheading: "13pt semibold"     # {Typography.subheading} - section header candidate
  body: "12pt regular"            # {Typography.body} - row label candidate
  bodyMono: "12pt monospaced"     # {Typography.bodyMono}
  label: "11pt regular"           # {Typography.label} - secondary field label
  labelStrong: "11pt semibold"    # {Typography.labelStrong}
  caption: "10pt regular"         # {Typography.caption} - description text under a row
  captionMono: "10pt monospaced"  # {Typography.captionMono}
  micro: "9pt bold rounded"       # {Typography.micro}
  # New role this doc adds: Apple's pane hero title is visibly larger than any existing Clip Settings role.
  heroTitle: "~22-24pt semibold (cap-height re-measured 16.5pt / 33px@2x in screenshot17.png 'General' - both the 'G' and the 'l' stem run from y275/276 to y307/308 - not the 12pt originally logged; a 13pt row label ('About') measures a 10pt cap-height for comparison, so this font is running noticeably larger than title2/title3; Clip has no equivalent today - nearest existing role is {type.heading} at 15pt, at least two steps too small, not one)"
  sidebarRow: "13pt regular (visual match to List/.sidebar default; not independently pixel-isolated, standard AppKit sidebar row text)"

spacing:
  inline: 4     # {Spacing.inline}
  tight: 8      # {Spacing.tight}
  related: 12   # {Spacing.related}
  comfortable: 16  # {Spacing.comfortable} - Apple's own row inset measures close to this: ~16-18pt left/right text inset inside a card, visually consistent across screenshot18.png/22.png/29.png
  group: 20     # {Spacing.group}
  section: 24   # {Spacing.section}
  panel: 28     # {Spacing.panel}
  loose: 32     # {Spacing.loose}
  # Apple measurements this doc grounds against the ladder above, so a builder can pick the nearest existing step:
  contentLeftMargin: 21   # pt; sidebar edge to content card edge, re-measured screenshot18.png at 41-42px@2x - nearest step: {spacing.group} (20)
  contentRightMargin: 21  # pt; content card edge to window's right edge, re-measured screenshot18.png at 42px@2x (was logged as 44px/22pt) - effectively the SAME margin as the left, not a slightly larger one - nearest step: {spacing.group} (20)
  cardRowInset: 11        # pt; re-measured 22px@2x, both screenshot18.png ("Name" row, card edge x486 to glyph x508) and screenshot26.png ("Size" row, card edge x34 to glyph x56) agree - this is NOT a match to {spacing.comfortable} (16pt) as originally logged; it sits between {spacing.related} (12) and nothing smaller on Clip's ladder, closer to {spacing.related}

radius:
  control: 5      # {AppTheme.graphite.radiusControl} = cornerRadius(10) * 0.5 - toggle/pill/badge scale
  card: 8         # {AppTheme.graphite.radiusCard} = cornerRadius(10) * 0.8 - row/card/thumbnail scale
  container: 10   # {AppTheme.graphite.radiusContainer} = cornerRadius(10) - sheet/panel/outer-edge scale
  # Apple's own measured radii, for comparison - macOS System Settings uses a rounder card than Graphite's 8:
  appleCard: "~14pt (visually continuous/superellipse corner, not a true circular radius; consistent across every screenshot's grouped cards, e.g. screenshot18.png/24.png/37.png)"
  appleSidebarPanel: "~12pt (the sidebar's own floating panel corner, screenshot17.png)"
  appleWindow: "~12pt (outer window corner, screenshot17.png top-left)"

elevation:
  # Apple draws almost no drop shadow inside System Settings itself - depth comes from the
  # panel/card/ground three-step and from real window-manager shadow at the outer edge only.
  none: "flat fill, no shadow, for a row inside a card (every screenshot)"
  windowShadow: "system window shadow only, at the outer traffic-light edge (screenshot17.png) - HIG default, not a custom value"
  clip.cardShadow: "none by default in Graphite; do not add one under a settings card - matches the Apple pattern of zero interior elevation"

motion:
  # Not independently measurable from static screenshots; these are HIG-documented conventions
  # cross-checked against what static frames are consistent with (no visible mid-animation frame
  # was captured, so nothing here is a frame-measured duration).
  toggleFlip: "~0.2s ease, HIG default NSSwitch animation - consistent with, not measured from, the static frames"
  disclosureExpand: "~0.25s ease-out, HIG default NSOutlineView/accordion expand"
  paneTransition: "cross-fade + slight slide on back/forward navigation, HIG default NavigationSplitView/NSSplitViewController push - consistent with the back/forward pill existing on every drill-down screenshot (e.g. screenshot18.png/19.png/21.png; NOT screenshot17.png, whose top-level 'General' pane has no history and shows no pill)"
  clip.hoverWash: "instant (no animation authored) - {SettingsHoverModifier}, .onHover with no transition"

layout:
  windowMinLogical: "900x620pt"           # {SettingsShell.swift line 21} .frame(minWidth: 900, minHeight: 620) - Clip's own current minimum
  windowMeasuredLogical: "~723x685pt"     # Apple's captured window, screenshot17.png - the raw PNG is 1456x1374px@2x, but its corners are opaque desktop background (18,18,18), not window content, so the file's own pixel size overstates the frame; edge-traced (black outline to black outline) the window itself spans x3-1450, y0-1370, i.e. ~1447x1370px@2x = ~723x685pt
  sidebarWidthClip: "215-300pt (min/ideal/max)"  # {SettingsShell.swift line 17} .navigationSplitViewColumnWidth
  sidebarWidthApple: "~223pt"             # measured screenshot17.png (446px@2x of 1456px@2x window, ~30.6%)
  sidebarRowHeight: 32                    # pt; measured screenshot17.png, selected "General" row spans 64px@2x (y676-740)
  cardRowHeightApple: "~36-37pt"          # pt; measured screenshot18.png, About page divider pitch 72-74px@2x
  heroIconTile: "52x52pt"                 # pt; re-measured screenshot17.png, gray gear tile is a square, 104x104px@2x edge-to-edge (not 104x106, and not visibly non-square)
  backForwardPill: "~72x34pt"             # pt; re-measured screenshot18.png (NOT screenshot17.png - General is a top-level landing pane with no history, so it shows no pill at all; the pill only appears on drill-down pages like "About"), pill fill spans 143px@2x wide exactly; height is ~68-69px@2x but the capture crops flush to the pill's own top edge so the true top is not directly visible
  toggleTrack: "~44x20pt"                 # pt; measured screenshot19.png, Wi-Fi toggle 88x40px@2x
  searchFieldClip: "capsule, 8pt horizontal / 6pt vertical inner padding, 10/10/6pt outer padding"  # {SettingsShell.swift searchField}
---

# Clip Settings Design Language

Clip already renders its Settings window as a native macOS `NavigationSplitView` - a sidebar of grouped tabs on the left, a scrolling detail pane on the right, drawn in the Graphite theme (`Clip/Theme/AppTheme.swift`). That structural choice was already right. What this document adds is Apple's own discipline on top of it: how System Settings groups rows into cards, how it writes a one-sentence purpose under every hero icon, how it never puts a control at the left edge of a row, how a value and a chevron coexist, and how the words themselves are chosen. Every claim below cites the screenshot it was read from (17.png-47.png, macOS Tahoe 26.5.2, dark, 2x) or the Swift file that already encodes a Clip value.

## 1. Identity and principles

**Rationale.** System Settings is not decorated; it is organized. Its entire visual identity is the discipline of grouping, not a color story - the palette is one dark ground, one card fill, one accent blue, and three semantic dots (green/red/gray). What reads as "polish" is really: every row obeys the same anatomy, every pane opens the same way, and no two panes invent their own layout. Clip's Settings should borrow that discipline, not Apple's exact palette - Clip already has Graphite, and swapping to Apple's dark palette would break every other themed surface in the app that shares `AppTheme`.

- **One ground, one card, one accent.** Across all 31 screenshots the only fills are the page background (`#1F212D`, screenshot18.png), the card fill (`#272934`, screenshot18.png) and the system accent blue used for selection and toggle-on (`#2557CA` / `#397CF6`, screenshot17.png/19.png). Everything else is text color and a handful of semantic dots.
- **Grouping is the whole layout system.** There is no free-floating control anywhere in 31 screenshots. Every control lives inside a rounded card, and every card lives under either the pane's hero header or a bold section title (screenshot18.png "macOS" / "Displays"; screenshot26.png "Dock" / "Desktop & Stage Manager").
- **Depth is spatial, not shadowed.** No screenshot shows a drop shadow on an interior card - depth comes from three flat layers (ground, card, selection) and hairline dividers only (screenshot18.png dividers at `#31333E`).
- **The window explains itself before it asks anything.** Every pane opens with an icon, a title, and one sentence of purpose before the first control (screenshot17.png "Manage your overall setup..."; screenshot19.png "Set up Wi-Fi to wirelessly connect..."). Clip's panes currently jump straight to controls with no equivalent sentence (`Clip/Views/SettingsView.swift` GeneralPane, `SettingsShell.swift` detail header is icon + title only, no purpose line).
- **Everything reversible drills down; everything immediate toggles in place.** A chevron always means "there is more, tap to see it" (screenshot17.png every row); a switch always means "this is on or off right here" (screenshot19.png Wi-Fi). Apple never uses a chevron to mean "toggle" or a toggle to mean "navigate."

## 2. Window anatomy and layout grid

**Rationale.** The window is a fixed two-column frame with generous, consistent margins - the grid is simple enough that a builder can reproduce it from four numbers: sidebar width, content left margin, content right margin, and row height. Consistency there is what makes 31 completely different panes feel like one window.

- **Frame.** Captured at ~723x685pt logical (screenshot17.png). The raw PNG is 1456x1374px@2x, but its four corners are flat desktop background (RGB 18,18,18), not window content - the window's own rounded rect, edge-traced to its outline, is closer to 1447x1370px@2x. Clip's own Settings window is `minWidth: 900, minHeight: 620` (`SettingsShell.swift` line 21) - wider than Apple's capture, which is expected since Clip's sidebar carries a sync row Apple doesn't have.
- **Sidebar.** A floating rounded panel, visually separated from the content column by a hairline and a gap, not a hard split divider - measured ~223pt wide, about 31% of the captured window (446px@2x of 1456px@2x, screenshot17.png). Clip's sidebar is a `NavigationSplitView` column at `min: 215, ideal: 232, max: 300` (`SettingsShell.swift` line 17) - already in the same range.
- **Content margins.** From the sidebar's right edge to the first card's left edge measures ~21pt (41-42px@2x, screenshot18.png); from the last card's right edge to the window's right edge measures the same ~21pt (42px@2x, screenshot18.png). These are the same margin, not two close-but-different ones, doubled as top/bottom via the hero header. Clip's detail header currently uses a 20pt horizontal inset (`SettingsShell.swift` line 168, `.padding(.horizontal, 20)`) - already correct, keep it.
- **Back/forward.** A single pill control, ~72x34pt (143px@2x wide exactly, screenshot18.png - NOT screenshot17.png, whose "General" pane is a top-level landing page with no navigation history and shows no pill at all), holding an active back chevron and a disabled-looking forward chevron (pixel-sampled: the back glyph peaks at RGB 233,233,235, the forward glyph at only 105,107,122 - i.e. back is enabled and forward is dimmed, the reverse of what was first logged here), immediately left of the pane title on every drill-down screen (screenshot18.png "About", screenshot21.png "Network"). Clip has no back/forward affordance today - `SettingsShell.swift`'s `router` swaps `tab` directly with no history stack.
- **Rows and cards.** A sidebar nav row is 32pt tall (64px@2x, screenshot17.png, "General" selected). A content-card detail row (label + value, no description) is ~36-37pt tall (72-74px@2x, screenshot18.png "About" page). A row that also carries a description line (Wi-Fi's own explanatory row, screenshot19.png) is taller still, growing with the text.
- **Corner radii.** Apple's own cards round at roughly 14pt-visibly rounder than Clip's Graphite `radiusCard` of 8pt (`AppTheme.swift`, `cornerRadius: 10 * 0.8`). This is a deliberate difference to keep, not fix - see section 9's "what Clip keeps different."

## 3. Navigation and information architecture (sidebar, drill-down, back/forward, search)

**Rationale.** Apple's sidebar is a two-tier tree: a search field and an account/status block pinned at the top (never scrolling away), then named groups of icon-tile rows. Selecting a top-level row can either show a page directly (Wi-Fi) or show a page that itself contains further drill-down rows (General > About, General > AirDrop & Continuity). Both patterns share one hierarchy rule: a chevron always means one more screen, reached by title, returned from by the back pill - never a modal, never a popover, for structural content.

- **Search first, always at the very top,** a rounded capsule field with a placeholder and a magnifying-glass icon, no label (screenshot17.png). Clip already matches this almost exactly: `SettingsShell.swift`'s `searchField` is a capsule with a leading `magnifyingglass` icon, placed above the list (lines 61-81) - this is the one piece of navigation Clip already built to spec.
- **Account/status block pinned under search, above the tab list** - Apple shows the signed-in Apple Account with an avatar and a status badge for "Software Update Available" (screenshot17.png). Clip's equivalent is the `syncRow` (sync status with a circular icon and one-line subtitle, `SettingsShell.swift` lines 83-114) - same position, same idea, different subject (sync state vs. Apple ID).
- **Grouped, not flat, tab list.** Apple's own sidebar groups are unlabeled at the very top (Wi-Fi/Bluetooth/Network/Battery cluster together with no header) then labeled from General onward implicitly by icon-tile color families rather than headers - but Clip's four named groups (`behaviour, appearance, content, data` in `SettingsShell.swift`) are a reasonable adaptation since Clip has fewer, more heterogeneous tabs than 30+ Apple panes.
- **Icon tiles, not bare SF Symbols, in the sidebar.** Every Apple sidebar row icon sits in a small rounded-square color tile (blue Wi-Fi, blue Bluetooth, green Battery, gray gear General - screenshot17.png). Clip's sidebar rows are a plain `Label(pane.title, systemImage: pane.symbol)` (`SettingsShell.swift` line 132) with no tile, relying on `.listStyle(.sidebar)` for the row chrome only - this is the single most visible sidebar gap versus Apple.
- **Drill-down via chevron, return via the back pill.** Every row that opens a sub-page ends in a plain `>` chevron with no other affix (screenshot17.png "About," "Storage," "AirDrop & Continuity"). The destination page's title appears next to the pill, replacing the previous title exactly (screenshot18.png "About"). Clip has no drill-down today: every tab is a single flat pane with no child pages, so this pattern is new territory Clip's shortcuts/paste-actions "further step" sheets already gesture toward (see section 6, ellipsis rule) but do not yet implement as a real pushed page.
- **In-pane search is a filter, not a destination.** Spotlight's own settings pane repeats the top-level search affordance inline, filtering rows already on the page and clearing to "Search Privacy..." rather than opening anything new (screenshot29.png/30.png). Clip's Privacy pane has an app search field with the same intent (`"Search apps"`, `SettingsPrivacyPane.swift`) - already aligned.

## 4. Components (the control vocabulary)

**Rationale.** Apple uses roughly a dozen controls, and every one of them appears inside a card row with the label on the left and the control flush right - never centered, never left-aligned on its own. Learning the vocabulary means learning the row anatomy once and then just swapping what sits on the right.

- **Toggle (switch).** ~44x20pt (88x40px@2x, screenshot19.png), blue when on (`#397CF6`), gray track when off (screenshot26.png "Minimize windows into application icon"). Always right-aligned, always paired with a plain sentence-case label on the left, never with its own visible caption inline (a caption sits below as its own line, see "description text" below).
- **Pop-up menu with a visible value.** A rounded pill showing the current value plus an up/down chevron glyph, right-aligned (screenshot22.png "Low Power Mode: Never", screenshot28.png "Automatically hide and show the menu bar: In Full Screen Only"). The value is always visible without opening the menu - this is progressive disclosure's summary half.
- **Stepper-as-pop-up.** Apple's numeric steppers in Settings are drawn as the same up/down-chevron pop-up rather than a +/- stepper control (screenshot28.png "Recent documents, applications, and servers: 10"). A literal `+/-` stepper does not appear anywhere in the 31 screenshots.
- **Slider with end-labels.** A horizontal track with a small icon or word at each end (screenshot27.png "Brightness" with sun icons; screenshot26.png "Size: Small...Large"; screenshot44.png "Key repeat rate: Off Slow...Fast"). Two-up sliders share a row when related (screenshot26.png "Size" and "Magnification" side by side).
- **Segmented control.** A pill divided into two or more filled sections, one highlighted blue (screenshot22.png "Last 24 Hours / Last 10 Days"; screenshot33.png "Output / Input"; screenshot45.png "Point & Click / Scroll & Zoom / More Gestures"). Used for switching a sub-view within one pane, never for switching panes.
- **Swatch/segmented picker for a value set.** A row of circular color or thumbnail swatches with the selected one ringed (screenshot25.png Theme "Color"; screenshot27.png "Larger Text/Default/More Space" as bordered thumbnails, one ring-highlighted).
- **Checkbox row.** A small square with a checkmark when active, used for independent multi-select membership (screenshot29.png Menu Bar Controls: Spotlight/Wi-Fi/Battery checked, Bluetooth/AirDrop unchecked).
- **Radio row.** A filled circle for a mutually-exclusive pair, drawn inline rather than stacked (screenshot37.png "Login window shows: (o) List of users  ( ) Name and password").
- **Push button with ellipsis for a sheet.** Every button whose label ends in "..." opens a secondary sheet or a system panel rather than acting immediately (screenshot18.png "Details...", screenshot30.png "Delete Search History...", screenshot47.png "Add Printer, Scanner, or Fax..."). A button with no ellipsis acts immediately (screenshot42.png "Manage...", "Upgrade...", both still have ellipsis actually - true immediate-action buttons are rarer; the reliable signal is presence vs. absence of "...").
- **Trailing "?" help button.** A small circular button with a question mark, bottom-right of a pane, opens Help - never inline with a specific row (screenshot21.png, screenshot23.png, screenshot27.png, appears in nearly every pane's bottom-right corner).
- **Inline "i" info button.** A small circle-i glyph beside a row's label, for a definition or detail popover, distinct from the pane-level "?" (screenshot20.png "[device name] 2024" device row; screenshot22.png "Battery Health"/"Charging"; screenshot41.png "[Owner Name] / Admin" row).
- **Chevron row (drill-down).** Label left, plain `>` right, no value shown - used when the destination has no single summarizable value (screenshot17.png "Storage").
- **Value + chevron row.** Label left, a value in secondary color, then `>` - used when the destination DOES have a summarizable state (screenshot37.png "Location Services: 2 >"; screenshot38.png count of full-access apps).
- **Status dot row.** A colored dot plus a word, under a device/service name, never the label's own color (screenshot20.png "Connected" green; screenshot21.png "Not connected" red / "Inactive" gray).
- **Hero card.** Icon (large, tiled, 52x52pt) + bold title + one centered sentence of purpose + inline "Learn more..." link, top of every pane, its own separate rounded card above the settings cards (screenshot17.png, screenshot19.png, screenshot24.png, screenshot32.png, screenshot37.png - this exact anatomy repeats on at least 8 of the 31 screenshots).
- **Description text under a row.** Secondary-colored, smaller than the row label, left-aligned, wraps to the card's own width, sits directly below the row it explains inside the same card (screenshot19.png Wi-Fi's own paragraph; screenshot26.png "Click wallpaper to show desktop"; screenshot34.png "True Tone" two-line explanation).
- **Section header outside the card.** Bold, larger than body text, left-aligned, sits above the card with no background of its own (screenshot18.png "macOS", "Displays"; screenshot26.png "Dock", "Desktop & Stage Manager").
- **Empty state.** Centered, secondary-colored, no icon, inside its own card (screenshot47.png "No Printers").
- **Badge count.** A small filled red circle with a white number, only ever on a sidebar row that needs attention (screenshot17.png "Software Update Available (1)").
- **Avatar row.** Circular photo/silhouette + name + role/status text, used for account identity, never for a generic list item (screenshot17.png Apple Account block; screenshot40.png "[Owner Name] / Admin", "Guest User / Off").

## 5. States

**Rationale.** Apple draws remarkably few explicit interaction states in a static screenshot set - hover and focus are AppKit's own system chrome and are not something the design "authors," but disabled, on/off, connection-status and loading states are all deliberately visible and worth naming.

- **Default.** Card fill `#272934`, primary-white label, no border (every screenshot).
- **Selected (sidebar).** Solid accent-blue fill behind the row, white label, no separate focus ring layered on top (screenshot17.png "General").
- **On / off (toggle).** Blue filled track with the knob at the trailing edge when on; gray track, knob leading, when off - the ONLY color signal, no separate label change like "On"/"Off" text beside it (screenshot19.png Wi-Fi on; screenshot26.png "Minimize windows into application icon" off).
- **Connected / not connected / inactive.** Three-way status via dot color only - green filled circle "Connected" (screenshot20.png), red filled circle "Not Connected" (screenshot20.png "[device name] 2024"; screenshot21.png "USB 10/100/1000 LAN"), gray filled circle "Inactive" (screenshot21.png "Firewall"). Never yellow for this particular tri-state; yellow is reserved for warnings (below).
- **Loading / working.** A spinning system progress indicator sits inline, right-aligned in the row it describes, replacing the chevron/value slot rather than the whole row (screenshot23.png "Checking for updates..."; screenshot20.png "Nearby Devices" section header, spinner instead of a value).
- **Disabled (implied, greyed value).** A pop-up whose value is rendered in dimmed secondary text rather than full white signals it is currently non-interactive (screenshot29.png "Focus: Show When Active" dimmed while Focus itself is unchecked above it) - the row is still visible, just visually quieter, never hidden.
- **Warning (not error).** A yellow/amber triangle glyph inline with a short label, sitting beside a status dot rather than replacing it (screenshot19.png "Privacy Warning" triangle beside the green "Connected" dot - the connection is fine, the concern is separate).
- **Destructive-adjacent.** No screenshot shows a literal red button in System Settings' own panes (destructive actions like "Delete Account..." use plain secondary button chrome, not red fill) - the danger color is reserved for text/dots, not buttons, in Apple's own vocabulary. Clip's `SettingsPalette.danger` is used more broadly today and should stay as-is; this is a place Clip already goes further than Apple on purpose (surfacing risk in button color, not just dot color).

## 6. Content and voice

**Rationale.** Apple's Settings copy is short, always sentence case, always addresses the user as "you," and never explains a control's mechanism - only its outcome. The one-line hero sentence pattern ("what this pane is for") and the "Show ..." toggle-naming convention are the two most copyable habits.

- **Sentence case everywhere**, including buttons and section headers - "Show related content," not "Show Related Content" (screenshot30.png). Exception: proper nouns and the pane's own hero title, which is capitalized as a heading (screenshot17.png "General").
- **Verbs lead action rows and buttons** - "Reset Quick Keys...," "Delete Search History...," "Empty Reclaimed folder" (screenshot30.png, `SettingsPrivacyPane.swift`).
- **"Show ..." is the toggle-naming convention** for anything that reveals UI rather than changing behavior outright - "Show Related Content," "Show previews," "Show user name and photo," "Show the Sleep, Restart, and Shut Down buttons" (screenshot30.png, screenshot32.png, screenshot36.png). Clip already uses this exact pattern in three places (`"Show a preview of what was copied"`, `"Show the keyboard hint footer"` - `SettingsMenuBarPane.swift`; `"Show the Welcome Guide"` - `SettingsView.swift` GeneralPane) - keep doing this, it is already correct.
- **An ellipsis at the end of a label means "one more step required," never "this label is truncated."** "Details...," "Add Printer, Scanner, or Fax...," "Set...," "Change..." (screenshot18.png, screenshot36.png, screenshot47.png). Clip already follows this precisely - every `SettingsSyncPane.swift`/`SettingsPasteActionsPane.swift` sheet-opening button already ends in "..." ("Export Settings...", "Disconnect This Mac...", "Reset").
- **One sentence explains what a feature is AND why you'd want it, never just what it is.** "Automatically adapt display to make colors appear consistent in different ambient lighting conditions" (screenshot27.png True Tone) states the mechanism and the payoff in one breath; it does not say "Enables True Tone."
- **No jargon without a plain-language gloss in the same sentence.** "Reduce Interruptions" and "Do Not Disturb" sit side by side with no further label needed because their names already are the plain-language gloss (screenshot34.png).
- **Numbers and units are always inline in the value slot, never as a separate label.** "10" for recent items (screenshot28.png), "7 days" for clipboard history retention (screenshot30.png), "3.6 KB of 5 GB Used" (screenshot42.png) - Clip already matches this exactly with `"Check the clipboard every \(prefs.pollIntervalMS) ms"` and `"Keep at most \(prefs.historyLimit) items"` (`SettingsView.swift` GeneralPane).
- **Counts appear as trailing plain numbers or short phrases on the row that owns them**, not as a separate badge unless it demands attention - "Location Services 2 >" is a plain count (screenshot37.png), while "Software Update Available (1)" in the sidebar is the one place a red badge is used, because it is an alert, not a tally (screenshot17.png).
- **A warning names itself explicitly and states the risk in the fewest words possible** - "Privacy Warning" plus the triangle, with no further sentence needed inline because the pattern (yellow triangle + two words) is already legible on sight (screenshot19.png). Clip's paste-actions/AI panes already do something similar with `"exclamationmark.triangle.fill"` glyphs (`SettingsAIPane.swift`) but pair them with fuller sentences - keep the fuller sentence for anything Clip-specific and risk-bearing (media/local storage, Keychain), since Clip's risks are less universally understood than Apple's own.

## 7. UX patterns that repeat

**Rationale.** These are the structural habits that make System Settings feel identical from pane to pane despite covering wildly different subjects - a builder extending Clip's Settings should check every new pane against this list before shipping it.

- **Progressive disclosure: summary value on the row, full detail behind the chevron.** "Location Services 2 >" tells you the count without opening anything; opening it lists exactly which two apps (screenshot37.png implies via the same pattern seen in "Files & Folders / 20 apps").
- **A hero card exists only at the top of a "landing" pane, never on a drilled-down sub-page.** "About" (a sub-page of General) has no hero card, no purpose sentence, no "Learn more" - it goes straight into grouped rows (screenshot18.png). Landing panes (Wi-Fi, Bluetooth, Accessibility, Notifications, Privacy & Security) all have one (screenshot19.png, screenshot20.png, screenshot24.png, screenshot32.png, screenshot37.png).
- **Grouping logic is "things you set once" above "things that change often."** Wi-Fi's hero + toggle + current network sit above the scrolling list of "Other Networks" (screenshot19.png); Sound's alert-sound settings sit above the live Output/Input device tabs (screenshot33.png).
- **Trailing action-buttons row, right-aligned, below the last card, is the universal "do something about this whole pane" slot** - "Options... ?" (screenshot22.png Battery), "Add Focus..." (screenshot34.png), "Add Account... ?" (screenshot41.png), "Add Printer, Scanner, or Fax... ?" (screenshot47.png). It is always the LAST thing on the pane, always right-aligned, and the "?" help button (when present) sits to its immediate right as a separate circular control.
- **Two-column sliders share a row when they are two aspects of the same control** ("Size" / "Magnification" for the Dock, screenshot26.png; not used when the two values are independent, which instead get separate rows).
- **Tabs (segmented control) live INSIDE a card, switching the rows below them, never switching the whole pane.** Sound's Output/Input segmented control redraws only the device table beneath it while the Sound Effects card above stays fixed (screenshot33.png). Trackpad's Point & Click / Scroll & Zoom / More Gestures does the same beneath a fixed preview area (screenshot45.png/46.png).
- **A live preview area sits above its own controls, never below or beside.** Trackpad's gesture-diagram illustration sits above the segmented control and its rows (screenshot45.png/46.png); Displays' "Built-in Display" hero mirrors this by sitting above the resolution/brightness controls (screenshot27.png).
- **A destructive or identity-changing action gets its own isolated card, separated from routine settings by real space**, not just a divider - "Delete Account..." sits alone at the very bottom (`SettingsSyncPane.swift` already isolates "Delete Account...," "Disconnect This Mac...," and "Forget Token..." this way).

## 8. Accessibility and density

**Rationale.** Apple's own Settings app is the accessibility reference implementation for macOS, so its density and contrast choices are worth treating as close to a floor, not a ceiling.

- **Row height (~36-37pt measured, screenshot18.png) clears the 44pt HIG touch-target guidance only when the click target is the FULL row width, not the text glyph** - Apple relies on the entire row being tappable via `.contentShape`, which Clip's `row(_:)` and `syncRow` already do (`SettingsShell.swift` lines 106-108, 131-134).
- **Every toggle, pop-up and slider is reachable and operable by keyboard** (Tab to focus, Space/arrow to change) as native AppKit controls - this is inherited for free by both Apple and Clip as long as Clip keeps using native `Toggle`/`Picker`/`Slider` rather than fully custom-drawn replacements, which `AppTheme.swift`'s own comment on `SettingsHoverModifier` explicitly protects ("deliberately NOT applied to a bare `Toggle`... AppKit has drawn its own hover/press highlight... since Big Sur").
- **Text contrast is measured, not assumed, in Clip's own settings layer already** - `SettingsPalette.swift`'s doc comment records `.secondary`/`.red`/`.green`/`.orange` failing 4.5:1 in light appearance and ships adjusted hex replacements that clear it in both appearances. Apple's own on-dark values were not independently re-measured for this document (see Known Gaps) but visually read as high-contrast white-on-`#272934` throughout every screenshot.
- **Density is comfortable, not compact** - Apple never uses a row shorter than ~36pt for anything with a control on it (screenshot18.png-47.png, no exceptions found), and always gives a description line its own full-width paragraph rather than truncating (screenshot19.png Wi-Fi's three-line purpose sentence). Apple's own row text inset measures ~11pt (22px@2x, re-checked on screenshot18.png and screenshot26.png), tighter than Clip's `Spacing.comfortable` (16pt) - the nearer existing token to standardize on is `Spacing.related` (12pt), not `Spacing.comfortable`; row HEIGHT (~36-37pt) is still the number worth holding as a floor, that part is unaffected.
- **Color is never the only signal for a tri-state (connected/inactive/not connected)** - each status dot is always paired with a word ("Connected," "Not Connected," "Inactive"), never a bare colored dot (screenshot20.png, screenshot21.png). Any new Clip status dot must keep the word.

## 9. Clip mapping

**Rationale.** Clip already has twelve tabs and a working `NavigationSplitView` shell; this section is not a rebuild, it is a row-by-row rewrite of each tab's existing copy into Apple's voice, plus the one Apple pattern each tab should adopt first, plus what Clip keeps different on purpose (and why that difference is a choice, not a gap).

### Getting Started
- **Apple pattern to adopt:** the checklist-card pattern (each step its own card - status glyph, title, one-sentence explanation, and the single action that advances it) rather than a single-Form list of switches, since every row here is a step to take once, not a preference to leave set.
- **Rows rewritten in Apple's voice:**
  - "Getting Started" hero - purpose: "Four steps and Clip is fully yours."
  - Progress line - "N of 4 done," plain count, no percentage or progress bar (a HIG-style status line, not a marketing meter).
  - Per-step card - title, one plain-language sentence, and its own action button ("Connect a Model," "Customize Tabs," "Sync Your Account," or "Open" as the fallback).
  - "Reopen the Welcome Guide" - a persistent action at the bottom of the checklist (moved here from General > Startup and opening in T3-M5 phase 2), so the one entry point back into onboarding lives with the pane whose whole job is pointing at every other tab, not duplicated across two.
- **What Clip keeps different on purpose:** Apple's own System Settings has no equivalent onboarding checklist tab at all (first-run guidance lives in a separate, one-time Setup Assistant, not inside Settings itself) - Clip keeps this as a permanent, always-reachable tab on purpose, since a clipboard manager's most-used features (the global shortcut, AI, sync) are each opt-in and easy to forget to finish setting up.

### Sync
- **Apple pattern to adopt:** the hero card (icon + title + one-sentence purpose + "Learn more...") - Sync is Clip's most consequential and least self-explanatory tab, and it currently has no purpose sentence at all before the token controls (`SettingsSyncPane.swift`).
- **Rows rewritten in Apple's voice:**
  - "Sync" - icon, hero title, purpose: "Combine this Mac's clipboard history with your other Macs over a token, so a copy on one shows up on the rest."
  - "Require HTTPS" (toggle) - description: "A token is a key. Over plain HTTP anyone on the network can read it in transit."
  - "Server" - not a chevron-drill today: `SettingsSyncPane.swift` line 908 wraps the advanced server fields in a `DisclosureGroup(isExpanded: $showAdvancedServer)`, an inline accordion expand within the same card (section 4/7's disclosure pattern), not a pushed sub-page. Keep it as a disclosure, or adopt the chevron-to-a-real-page pattern deliberately - don't describe it as already being the latter.
  - "Disconnect This Mac..." / "Forget Token on This Mac..." / "Delete Account..." - isolated in their own card at the very bottom, per section 7's destructive-action pattern (already done).
- **What Clip keeps different on purpose:** the raw token text field and QR/copy affordances have no Apple equivalent (Apple's iCloud sign-in is a system sheet, not a pasted secret) - Clip must keep its own explicit token UI because there is no OS-level identity to borrow.

### General
- **Apple pattern to adopt:** the hero card - `GeneralPane` (`SettingsView.swift`) currently opens straight into "Startup"/"History"/"Opening"/"Pasting" section headers with no purpose sentence, unlike every Apple landing pane.
- **Rows rewritten in Apple's voice:**
  - "General" - purpose: "Set how Clip starts, how much it remembers, and what happens when you paste."
  - "Launch at login" (toggle) - description: "Clip can start itself when you log in." (already exact Apple phrasing style, keep verbatim)
  - "Keep at most 200 items" (stepper-as-pop-up per section 4, not a raw stepper)
  - "Check the clipboard every 200 ms" (stepper-as-pop-up)
  - "Skip text larger than 500 KB" (stepper-as-pop-up)
  - "Paste automatically after choosing an item" (toggle)
  - "Clear history when quitting" (toggle)
- **What Clip keeps different on purpose:** Apple's General pane is a directory of OTHER panes (About, Storage, AirDrop); Clip's General is genuinely flat behavior settings, so it should NOT grow chevron-drilldowns just to imitate the shape - only adopt the hero sentence and stepper-as-pop-up styling.

### Shortcuts
- **Apple pattern to adopt:** value + chevron rows for each bound shortcut, and the trailing "Restore all defaults" + "?" button row (section 7) instead of a bare "Reset" button.
- **Rows rewritten in Apple's voice:**
  - "Show 'Clipboard History'" (system-wide shortcut, value shown as the recorded keys, chevron to re-record) - Clip already writes `"Show “\(name)”"` (`SettingsShortcutsPane.swift`), which already matches the "Show ..." convention exactly.
  - "Item shortcuts" section header outside the card, exactly per section 4's rule.
  - Description under the section: "These paste one specific item from anywhere." (already present, keep verbatim - it already states what and why in one sentence).
- **What Clip keeps different on purpose:** Apple's own Keyboard Shortcuts pane (screenshot44.png "Keyboard Shortcuts...") is a single flat table in a sheet; Clip's per-item shortcut list is inherently dynamic (grows with pinned items) and belongs in the main pane, not a sheet, because it is core functionality rather than a rarely-touched customization.

### Themes
- **Apple pattern to adopt:** the swatch/segmented picker (section 4) for "Or choose one," matching Apple's own Theme > Color row (screenshot25.png) almost exactly already - and the two-column preview-above-controls pattern (section 7) for the live theme preview.
- **Rows rewritten in Apple's voice:**
  - "Appearance" section header, "Dark theme" toggle - directly modeled on screenshot25.png's own "Appearance: Auto/Light/Dark" swatches.
  - "Corner radius: 10" - stepper-as-pop-up or slider with end-labels ("Sharp...Round"), not a bare number.
- **What Clip keeps different on purpose:** the AI-assisted "Describe a theme" / "Generate" flow has no Apple analog at all - Apple never generates a design from a prompt - and should keep its own distinct voice ("Ask for a change," "Describe the theme you want") rather than forcing Apple's imperative brevity onto a conversational feature.

### Tabs
- **Apple pattern to adopt:** the "Menu Bar Controls" checkbox-row pattern (section 4, screenshot28.png) for "Available tabs," since Tabs is fundamentally a multi-select membership list (visible vs. hidden), exactly like Apple's own menu-bar-item list.
- **Rows rewritten in Apple's voice:**
  - "Visible tabs" section header, each tab a checkbox row with a drag handle, not two separate lists if that can be avoided - Apple keeps membership as ONE list with checkmarks (screenshot28.png) rather than two lists with an in/out boundary; Clip's current two-list "Available tabs / Visible tabs" split is a reasonable alternative Apple doesn't use but Clip should keep, see below.
  - "Restore defaults" push button, right-aligned, no ellipsis (an immediate, non-sheet action).
- **What Clip keeps different on purpose:** the two-list "Available / Visible" split (`SettingsTabsPane.swift`) is clearer than Apple's single-checkbox-list for reordering, since Clip's tab ORDER matters (it is the panel's own tab bar order) and Apple's menu-bar items do not have a user-visible order in the same way - keep the two-list layout, adopt only the row/checkbox visual language.

### Menu Bar
- **Apple pattern to adopt:** this tab is already closest to Apple's own Menu Bar pane in spirit (screenshot28.png) - adopt the exact row grammar: icon + label + a trailing "Options..." button on rows that need one, instead of nested toggles.
- **Rows rewritten in Apple's voice:**
  - "Show a preview of what was copied" (toggle) - already present, exact match to the "Show ..." convention.
  - "Show the preview for 3 seconds" - stepper-as-pop-up, not free text.
  - "Also show Clip in the Dock" (toggle) - directly modeled on Apple's own "Also show Clip in the Dock"-style dual-surface toggles.
- **What Clip keeps different on purpose:** none identified - this tab should track Apple's Menu Bar pane the closest of all eleven, since the subject matter is nearly identical.

### AI
- **Apple pattern to adopt:** the hero card with purpose sentence, and value + info-button rows (section 4, "i" glyph) for "Model," since a model id is exactly the kind of value that benefits from an inline definition popover rather than a full sentence every time.
- **Rows rewritten in Apple's voice:**
  - "AI features" hero - purpose: "Let Clip rewrite, translate, or summarize what you copy, using a connection you provide."
  - "Enable AI features" (toggle) - description: "AI is off. Your connections and API keys are kept." (already present, exact Apple-style reassurance-on-off pattern).
  - "Test connection" / "Test all" - immediate push buttons, no ellipsis (they act now, no sheet).
  - "Add connection..." - ellipsis correctly present (opens a sheet).
- **What Clip keeps different on purpose:** the primary/backup failover language ("The main connection failed; the backup answered") is Clip-specific reliability messaging with no Apple equivalent (Apple Intelligence has no user-visible failover model) - keep it explicit and technical here, since silently failing over without saying so would be worse than Apple's own silence.

### Paste Actions
- **Apple pattern to adopt:** the "Menu Bar Controls" checkbox-membership pattern again (section 4) for which actions appear "In the menu," plus the "Between... and..." wording already present as a good match to Apple's plain-sentence style.
- **Rows rewritten in Apple's voice:**
  - "Paste actions" hero - purpose: "Run a quick action on what you're about to paste, right from the menu."
  - "12 in the menu" (trailing count on the section header, per section 6's counting rule).
  - "These need a model connection." - description line, styled exactly like Apple's own dependency notices (e.g. "This Mac is discoverable as..." under Bluetooth, screenshot20.png).
- **What Clip keeps different on purpose:** the example-prompt placeholder text ("Rewrite this as a one-paragraph LinkedIn post, no hashtags.") is necessarily longer and more specific than any Apple placeholder - Apple never shows example content this concrete because its controls are never free-text prompts.

### Privacy
- **Apple pattern to adopt:** Privacy & Security's own value + chevron list (screenshot37.png, "Files & Folders / 20 apps >") for "Ignored apps," and its search-as-a-label field styling (screenshot29.png-style capsule) for "Search apps."
- **Rows rewritten in Apple's voice:**
  - "Privacy & Security" hero - purpose: "Control what Clip remembers, and where it keeps it."
  - "Ignore content marked confidential" (toggle) - already present, already sentence-case and verb-led.
  - "Where your data lives" (chevron row to Diagnostics/storage path detail) - modeled on Apple's own "Where your data lives"-style destination rows.
  - "Reclaim 240 MB" (push button whose label carries the live number inline, per section 6's inline-numbers rule) - already present and correct.
- **What Clip keeps different on purpose:** "Empty Reclaimed folder" needs a confirmation step Apple's own destructive flows also use (a second sheet, not inline) - keep that confirmation even though it adds a step Apple sometimes skips for lower-stakes actions, because Clip's reclaim is irreversible in a way most Apple toggles are not.

### Backup (Export pane)
- **Apple pattern to adopt:** the section-header-outside-card grouping for "Configuration" vs. "Content" vs. "Design library" (screenshot18.png's "macOS"/"Displays" pattern), and the "Select all / Select none" trailing row (section 7's trailing-action-row pattern).
- **Rows rewritten in Apple's voice:**
  - "Backup" hero - purpose: "Save your settings, themes, and history to a folder, or bring them back from one."
  - "API keys are never exported. They stay in the macOS Keychain." - description line, styled like Apple's own reassurance-under-a-toggle text (e.g. "This Mac is discoverable as..." pattern).
  - "Also restore settings, themes and shortcuts" (toggle) inside the Import flow.
- **What Clip keeps different on purpose:** per-scope checkboxes (Configuration/Content/Design library) with live byte counts have no Apple analog (Apple's own Time Machine/Migration Assistant hides this granularity) - keep the granularity, since Clip users manage a single plaintext data folder and deserve to see exactly what leaves it.

### Diagnostics
- **Apple pattern to adopt:** the empty state (section 4, "No Printers" - screenshot47.png) for "Nothing needs repair right now," and the isolated destructive/repair card pattern (section 7) for repair actions that touch the Keychain.
- **Rows rewritten in Apple's voice:**
  - "Diagnostics" hero - purpose: "Check Clip's own health, and fix what it can fix itself."
  - "Nothing needs repair right now." - centered, secondary-colored, no icon, exactly per the empty-state spec.
  - "Repair AI Key Access..." (ellipsis correct - this opens a Keychain-prompting flow, i.e., "one more step").
  - "Reset Accessibility Permission" (no ellipsis - immediate, no further step beyond a system dialog Clip doesn't control).
- **What Clip keeps different on purpose:** "Copy Diagnostic Report" and the machine-readable diagnostic dump are developer-facing in a way nothing in Apple's own Settings is (Apple never shows raw diagnostic text to a general user) - keep this technical register here specifically, since Diagnostics' whole purpose is a paste-into-a-bug-report artifact.

### Machine-checkable pane list

One line per `Settings*Pane.swift` file, in `SettingsTab`'s own declared
order (`Clip/Core/SettingsWindowController.swift`). A qa-probe assertion
reads this list back out of this file and compares it against every
`Clip/Views/Settings*Pane.swift` file that actually exists on disk - if a
pane is added, removed, or renamed in one place and not the other, that
assertion fails. General has no entry: it is defined inline in
`SettingsView.swift`, which does not match the `*Pane.swift` name this list
(and the probe's glob) both use - eleven lines below, one per tab other
than General, out of Clip's twelve tabs.

```
Clip/Views/SettingsGettingStartedPane.swift
Clip/Views/SettingsSyncPane.swift
Clip/Views/SettingsShortcutsPane.swift
Clip/Views/SettingsThemePane.swift
Clip/Views/SettingsTabsPane.swift
Clip/Views/SettingsMenuBarPane.swift
Clip/Views/SettingsAIPane.swift
Clip/Views/SettingsPasteActionsPane.swift
Clip/Views/SettingsPrivacyPane.swift
Clip/Views/SettingsExportPane.swift
Clip/Views/SettingsDiagnosticsPane.swift
```

## Known Gaps

Stated plainly so nothing here is mistaken for a measurement it is not.

- **Font sizes are not independently pixel-measured for most roles.** Only the hero title's cap-height was isolated (screenshot17.png "General", both the 'G' and the 'l' stem measure 33px@2x = ~16.5pt cap-height - notably larger than title2/title3, and larger than this doc first logged). Row-label, description, and section-header sizes are stated as relative hierarchy only, cross-checked by eye against Clip's own named `Typography` scale, not by measuring individual glyph heights in every screenshot.
- **Corner radii for Apple's cards and window are visual estimates (~14pt card, ~12pt sidebar panel and window), not edge-traced sub-pixel measurements** - macOS draws continuous ("squircle") corners, which do not have a single true circular radius the way a pixel-scan can cleanly isolate the way a flat divider or a solid-fill row can.
- **`SettingsPalette.note` (secondary text) was not independently re-measured against Apple's own screenshots** - its light/dark hex values are read from `SettingsPalette.swift`'s own doc comment, which documents contrast ratios against Clip's own window/control backgrounds, not against Apple's `#1F212D` ground.
- **Motion values are HIG-documented conventions, not frame-measured durations** - no screenshot captured a mid-animation frame (toggle flip, disclosure expand, pane push), since all 31 are static end-states, so every motion number in the YAML block is explicitly marked as "consistent with," never "measured from."
- **Two screenshots have no accompanying full-window frame** (Passkeys Access for Web Browsers, screenshot38.png, and one Trackpad tab, screenshot46.png, are cropped to their content area only) - their sidebar-relative geometry was inferred from the other 29 frames' consistent window chrome, not measured directly on those two.
- **The exact Apple font family and weight tokens (San Francisco Text vs. Display, exact weight names) were not extracted** - macOS renders system UI font by role automatically, and no screenshot exposes a font inspector; every type claim here is a size/weight description, not a named token like `SF Pro Text Semibold`.
- **Apple's spring/easing curve values are unknowable from static PNGs** - anything in the `motion` YAML block beyond "this kind of thing happens" (e.g. a specific cubic-bezier) would be fabricated, so none is given.
- **The four semantic status/warning colors (`statusGreen`, `statusRed`, `statusGray`, `warningTriangle`) were re-measured by direct pixel sampling for this pass and turned out to differ, by tens of RGB units, from the textbook HIG systemColor(dark) swatches this doc first assumed.** All four moved in the same direction (measured green and yellow read lighter/less saturated in blue, measured red and gray read less saturated) while every neutral fill sampled the same way (ground, card, divider, toggle-on, link) matched its textbook/source value within 1-2 units. The likely explanation is a Display P3-to-sRGB byte interpretation difference in how the screenshots were captured or cached, not four independently mis-specified colors - but this was not independently confirmed, so treat the measured hex values now in the YAML as the operative ones (they are what actually renders in the cited frames) and treat the "HIG systemColor" labels as provenance/intent only, not as the number to implement.
