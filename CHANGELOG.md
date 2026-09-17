# Changelog

This is what the in-app updater shows people, so write every entry for the
person reading it in the update window, not for another engineer. One line
per change, plain language, no internal file or class names. Dates are
DD/MM/YYYY.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Settings can follow your Mac's light and dark setting or stay on one of
  them. The choice sits at the top of Settings > General, and applies to the Settings window only: the clipboard panel keeps
  following your Mac, because it appears over whatever you are working in.
  Themes that come in only one form, like Aurora, say so instead of offering
  a switch that could not do anything.

- Deleting a clip can be taken back. The notice at the top of the panel names
  what went and offers Undo for twelve seconds, and Command+Z does the same
  thing. Nothing is actually removed until that window closes, so the item
  comes back with its pin, its shortcut and its place in the list, and your
  other Macs never hear about a delete you took back.

- Settings > General > History now has a "Combine copies of the same thing"
  switch, so you can see and turn off the setting that keeps one copy
  instead of two when you copy the exact same text or image again.

### Changed

- Settings now takes its colours from the theme you chose, instead of the
  Mac's own greys. Pick Aurora and Settings is the same deep blue as the
  panel; pick Ivory and it is light. It also reads the theme's light or dark
  mode rather than the system's, so a light theme stays readable while macOS
  is in dark mode.

- The paste action list now has a hairline gap between rows, so a selected
  action never looks stuck to the one below it.
- "Show the Welcome Guide" moved from Settings > General into Settings >
  Getting Started, next to the rest of the setup checklist it belongs with.
- Settings > Diagnostics now has one "Copy Diagnostic Report" button instead
  of five separate report pages (Shortcuts, Storage, Keychain, Sync, AI);
  the copied report still contains everything those pages showed.

### Fixed

- Settings pages that ignored the light or dark choice now follow it. Getting
  Started kept the panel's dark cards on a light page, the Tabs list stayed
  white when Settings was set to dark, and every button and shortcut chip in
  Settings took its colour from the panel rather than the window.

- A backup file is now readable only by you. Clip was careful with its own
  database but wrote the backup with whatever permissions the system
  defaulted to, so on a Mac with more than one account another person could
  open a backup sitting in your Documents folder and read everything in
  it.

- In the theme builder's color-guidance panel, a long description of where a
  color is used could get cut off mid-word; it now wraps onto a second line
  instead.
- In the theme builder, a light color theme viewed while your Mac was set to
  Dark Mode made the guidance panel's heading and labels almost impossible to
  read, and left an unlabeled white shape floating under the theme name field.
  Both now match the theme you are actually editing.
- The theme builder's name field, its section headings, every swatch's
  description and hex value, the Dark theme switch, both sliders, and the
  Inspect/Cancel/Undo/Save theme buttons could all still paint from your
  Mac's own light or dark setting instead of the theme you were editing - a
  light theme edited while your Mac was in Dark Mode could turn the name
  field solid black with barely visible text. Every one of them now follows
  the theme itself.
- A copied link's title is now fetched more safely: it can no longer be sent
  to an address on your own machine or local network, a redirect can no
  longer send it somewhere private either, and a page's response is now cut
  off at a real size limit instead of being downloaded in full first.
- If today's automatic backup does not complete, you now see a notice about
  it instead of it failing silently.
- Restoring from a backup now tells you if the safety copy of your current
  data could not be made, instead of quietly proceeding without one.
- The close, discard, copy and paste buttons in the paste-action window no
  longer show their tooltip all the time - it now only appears when you
  point at the button or reach it with the keyboard, same as everywhere else.
- Lowering your history limit right after a burst of copying could leave the
  older items back in your history the next time you launched Clip, even
  though they had already dropped off the list. Trimming now always wins,
  so a lowered limit stays lowered.
- A backup that could not include a theme or a media file used to say
  nothing about it. It now names what was left out, so you know to go and
  re-add it by hand. Backups made by earlier versions still open.

## [2.1] - 04/09/2026

### Added

- Clip can now check for updates and install them itself. Turn automatic
  checks on, or check right now, from Settings > General > Updates.
- A new default theme, Clip, follows your Mac's light and dark appearance on
  its own instead of pinning one look.

### Changed

- Clipboard history is unlimited by default now. If you'd rather cap how
  much Clip keeps, that's still there as an explicit setting.
- Copying something you already have no longer adds a duplicate entry,
  whether the repeat happened on this Mac or arrived through sync from
  another one.
- Filtering a large history while you type is dramatically faster: on a
  5,000-item library, the cost per keystroke dropped from 78.6 ms to
  6.17 ms.
- Every built-in theme now meets the strictest (AAA) contrast standard, so
  text stays easy to read across all of them.

### Fixed

- The copy confirmation could stay silent right after launching Clip; it
  now shows reliably from the first copy.
- Option+P and Option+Delete could stop responding after you opened and
  closed an item's detail view.
- A filter chip's selection ring could look stuck on after a click even
  though nothing was actually selected.

Versions before 2.1 predate this changelog.
