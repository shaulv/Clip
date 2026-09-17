# Clip's update mechanism (Sparkle)

Before this (lane-m7, 2026-09-04), Clip had no update path at all: a user on
2.0 could never receive a fix short of downloading a new DMG by hand and
dragging it over the old install. This is what closes that gap.

## What is wired

- **Framework**: [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9,
  added as a Swift Package Manager dependency through `regen-project.py`
  (never by hand - a hand-patched `project.pbxproj` is exactly what this
  generator exists to avoid; see its module docstring).
- **App code**: `Clip/Clip/Core/Updates/UpdateController.swift` is the one
  place `SPUStandardUpdaterController` is created and driven. `AppDelegate`
  calls `UpdateController.shared.start()` at launch.
- **User-facing controls**: Settings > General > Updates
  (`Clip/Clip/Views/SettingsView.swift`, `GeneralPage.updates`) - a toggle for
  automatic checks and a "Check for Updates…" button. The toggle is backed by
  `PreferencesModel.checkForUpdatesAutomatically` (`Theme/ThemeManager.swift`)
  and mirrored onto Sparkle's own flag live, no relaunch required.
- **Info.plist keys**: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
  `SUScheduledCheckInterval` (once a day).

## The signing key

Sparkle signs every update with an EdDSA (Ed25519) key pair. The PUBLIC half
is committed - `Vre6A3KvzUMuYG1XzIrPwDLJpOgrOR15AsaRCJzHWp8=` in
`Clip/Info.plist` (`SUPublicEDKey`) - because that is what makes the
mechanism trustworthy: Sparkle refuses to install anything not signed by the
matching private key. Committing it is correct, not a leak, and safe in an
open-source repo.

The PRIVATE half must never enter the repository, ever, in any commit,
branch or history. It currently lives at:

```
~/.clip-sparkle/clip_sparkle_ed25519_private_key
```

as a single line: the base64-encoded 32-byte Ed25519 seed (the same shape
Sparkle's own `generate_keys` tool exports with `-x`). File permissions are
`600` (owner read/write only); the containing directory is `700`.

**Back it up.** Losing this file means every future release must ship under
a NEW key, and no existing install can verify (or therefore accept) an
update signed by the new one - effectively cutting off every user already
out there until they reinstall by hand. Back it up somewhere that is not
this repo and not this machine alone: a password manager's secure-note/file
attachment, or an encrypted volume kept off this Mac, are both fine. Do NOT
put it in Google Drive, Dropbox, iCloud Drive, or any other synced folder
this repo itself might live inside - that is exactly the same mistake as
committing it, just one layer removed.

**Rotating it** (if it is ever lost or suspected compromised): generate a
new key pair, update `SUPublicEDKey` in `Info.plist`, and understand that
every user on an OLD version will not be offered the update that carries the
new key, because their copy of Sparkle is still checking signatures against
the OLD public key baked into their build. There is no way around a user
gap here; it is inherent to how Sparkle's trust model works, not a bug in
this setup.

## How a release actually happens now

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion` if you track
   build numbers separately) in `Clip/Info.plist`.
2. Run `./release.sh` from `Clip/`. It:
   - runs `package.sh` (regenerates the project, builds Release, signs it
     with the one stable local identity, builds the DMG - see "Why this
     ships unnotarised" below; there is no Developer ID branch to fall out
     of, and there never will be);
   - fetches Sparkle's own `sign_update` command-line tool (cached under
     `dist/.sparkle-tools/`, which is gitignored) if it is not already
     there;
   - signs the DMG against the private key at
     `~/.clip-sparkle/clip_sparkle_ed25519_private_key` (override with
     `CLIP_SPARKLE_PRIVATE_KEY_FILE`);
   - inserts a new `<item>` at the top of `appcast.xml` with the version,
     the enclosure URL (built from the `DOWNLOAD_BASE` placeholder - see
     below), the file length and the EdDSA signature.
3. Upload the DMG and the updated `appcast.xml` to wherever `SUFeedURL`
   actually points, and commit the `appcast.xml` change.

`./release.sh --dry-run` does everything except step 3's file write - it
prints the `<item>` it would have inserted, which is the fast way to check
a release before touching the committed feed file.

## The placeholder feed URL

`SUFeedURL` in `Clip/Info.plist` and `DOWNLOAD_BASE` in `release.sh` both
currently point at `https://updates.example.invalid/clip/...` - a
placeholder, not a real host. `.invalid` is the reserved TLD for exactly
this (RFC 2606): it will never resolve, so nobody's build silently starts
polling a real machine by accident. This is deliberate and documented, not
an oversight - Clip is going open source and this repo should not hard-code
a hosting decision nobody has made yet.

**Before shipping a real release to real users**, point both at wherever the
DMGs and `appcast.xml` are actually going to be hosted (GitHub Releases +
raw.githubusercontent.com, a bucket, the project's own domain - anything
served over plain HTTPS works, Sparkle does not require anything special of
the host beyond that).

## Before you turn on automatic updates in your fork

If you skip this, the failure mode is safe: Sparkle refuses anything not
signed by the matching private key, so a fork that forgets these steps
simply never receives updates - it will not, and cannot, silently accept an
update signed by the upstream project's key. Still worth doing properly,
since "silently never updates" is a bad first-run experience for your users.

1. **Generate your own EdDSA key pair.** Do not reuse the key committed in
   this repo - that key belongs to the upstream project, and its private
   half is not in the repo for you to find.
   ```bash
   ./bin/generate_keys -x /tmp/your_fork_private_key
   ```
   (`generate_keys` ships inside Sparkle's own distribution, fetched the
   same way `release.sh` fetches `sign_update` - see "How a release
   actually happens now" above.)
2. **Put the new public key in your own `Info.plist`.** Replace
   `SUPublicEDKey` with the public half `generate_keys` printed; keep the
   private half out of the repo, exactly as described under "The signing
   key" above.
3. **Point `SUFeedURL` at your own appcast, on your own host.** Update it in
   `Clip/Info.plist` and update `DOWNLOAD_BASE` in `release.sh` to match, so
   your builds fetch your feed, not a placeholder that will never resolve.
   ```bash
   grep -n "updates.example.invalid" Clip/Info.plist release.sh
   ```
4. **Know what happens if you ever sign a release with the upstream
   project's key by mistake.** It will not install: every user's copy of
   Sparkle checks the update's signature against the public key baked into
   *their* build, and a build compiled with your `SUPublicEDKey` will only
   ever accept an update signed by your matching private key.
5. **Verify a built DMG's signature before you publish it**, the same way
   `release.sh` verifies its own output.
   ```bash
   ./bin/sign_update --verify --ed-key-file /tmp/your_fork_private_key \
     Clip-<version>.dmg <signature-from-appcast.xml>
   ```
   No error printed means it verified; anything else means the DMG and the
   signature in your `appcast.xml` do not match, and you should not publish
   that entry.

## What was verified locally, end to end, on 2026-09-04

- `xcodebuild -resolvePackageDependencies` resolves Sparkle 2.9.6 from
  `https://github.com/sparkle-project/Sparkle` cleanly.
- Debug, Testing and Release configurations all build with Sparkle linked.
- `./package.sh` produces a signed `Clip-2.0.1.dmg` with `Sparkle.framework`
  correctly embedded and code-signed inside `Contents/Frameworks/`.
- `./release.sh` (real run, not `--dry-run`) produced a genuine EdDSA
  signature over that DMG and inserted a real `<item>` for 2.0.1 into
  `appcast.xml`.
- That `appcast.xml`, plus the DMG, were served from a local
  `python3 -m http.server` on `127.0.0.1`. A Debug build with its
  `CFBundleShortVersionString` set back to `2.0` and its built `Info.plist`'s
  `SUFeedURL` pointed at that local server was launched; the local HTTP
  server's access log recorded a successful `GET /appcast.xml` (`200`) from
  the running app, at both its launch-time automatic check and again on the
  scheduled interval - proving `UpdateController.start()` actually arms
  Sparkle's check, and that it fetches the exact feed `SUFeedURL` names.
- Signing round-trip: `sign_update --ed-key-file <seed file> <file>`
  followed by `sign_update --verify --ed-key-file <same seed file> <file>
  <signature>` succeeds silently (no error = verified) against both a throwaway
  test key and the real project key, confirming the Python-generated
  (`cryptography` library) Ed25519 seed is byte-for-byte compatible with
  Sparkle's own key format - they are the same RFC 8032 Ed25519
  representation.

**Not verified locally** (would require an interactive GUI session and
clicking through Sparkle's own "Update Available" dialog, which nothing in
this sandboxed environment can do): the actual download-verify-relaunch
flow after the feed is found. The feed being found, parsed, and the
DMG/signature being crypto-compatible is as far as this environment can
prove; the remaining step is standard Sparkle behavior this project does not
customize, so it is a low-risk gap, not an unknown.

### Also verified, for the unnotarised default path (M14, 2026-09-04)

- `./package.sh` run four times in a row: `security find-identity -v -p
  codesigning` returned the byte-identical listing before and after every
  run - no new identity was ever created, and no Keychain-access prompt
  appeared, because "Clip Local Signing" already existed on this machine
  and `package.sh` found and reused it every time. `codesign -dvvv` on each
  resulting `Clip.app` shows `Authority=Clip Local Signing` on both the app
  and the embedded `Sparkle.framework` binary.
- The Release build produced this way launches
  (`CLIP_QA=1 CLIP_QA_SANDBOX=1 CLIP_QA_SANDBOX_NAME=m14`), stays running,
  and writes no crash log - see "Why this ships unnotarised" below for the
  Library Validation bug this surfaced and fixed along the way.
- `spctl -a -vv --type execute` against that same signed-only build reports
  `rejected` - the honest, documented Gatekeeper-warning path for a
  downloaded DMG stands exactly as README.md and the DMG's own
  "Read me first.txt" already describe it.

## Why this ships unnotarised, and why that is fine for Sparkle

Clip does not have, and will never have, a paid Apple Developer ID. That is
a permanent decision, not a stage this project is passing through -
notarisation costs $99/year and this is a free, open-source app. `package.sh`
signs every build with one stable self-signed identity ("Clip Local Signing")
and has no code path that even looks for a Developer ID, let alone submits
anything to `notarytool`. See the comment block at the top of `package.sh`
for the mechanics, and `docs/LOCAL-SIGNING.md` for the identity itself.

The question that matters is whether Sparkle's update mechanism actually
needs notarisation to work. It does not, and this is not an assumption -
it was checked against Sparkle's own vendored source
(`SourcePackages/checkouts/Sparkle` under the build's DerivedData) and
against Sparkle's own published documentation, not inferred:

- **Sparkle's real integrity control is its own EdDSA signature, not Apple's.**
  Sparkle's documentation lists notarising and code-signing with a Developer
  ID as something to do "if possible" - not a requirement - alongside the
  EdDSA signature on the update archive itself, which Sparkle treats as the
  control that actually matters. An app store's worth of comments in this
  project's own `UpdateController.swift` and this file already document that
  `SUPublicEDKey` is the one thing that must never be swappable by an
  attacker; notarisation was never that.
- **Sparkle strips the quarantine attribute from the downloaded update
  before it ever gets Gatekeeper-evaluated.** `SUFileManager.m`'s
  `releaseItemFromQuarantineAtRootURL:` does exactly that, recursively, and
  `SUPlainInstaller.m` (the installer used for a normal, non-sandboxed app
  like Clip) calls it unconditionally on every installation, before moving
  the new bundle into place. The quarantine flag is what makes Gatekeeper
  treat something as "downloaded from the internet" in the first place;
  Sparkle removes it before that check would ever run against the new build.
- **Sparkle's own supplementary Gatekeeper pre-warm is explicitly
  best-effort.** Since macOS 14.4, `SUPlainInstaller.m` also runs
  `gktool scan` on the new bundle after installing it, purely to pre-warm
  Gatekeeper's cache so the user does not see a brief "Verifying..." spinner
  on first launch of the update. Its own comment says what happens if that
  scan fails (which it will, for an unnotarised app): `"Not a fatal error"`
  - logged, and installation proceeds regardless.

**Verified directly, not just read**, on 2026-09-04, against a Release build
signed only with "Clip Local Signing" (no Developer ID anywhere in the
chain): the packaged `Clip.app` launches cleanly, with no Gatekeeper block
and no dyld signature error, when it carries no quarantine attribute - which
is exactly the state a Sparkle-installed update is in after the quarantine
strip above runs. `spctl -a -vv --type execute` against that same build
(which assesses as if the item were quarantined, regardless of whether it
actually is) reports `rejected` - confirming the *download-a-DMG-yourself*
path genuinely does hit Gatekeeper's policy and needs the right-click-Open
step this project already documents; it is the Sparkle path specifically
that sidesteps it, for the reasons above, not "notarisation doesn't matter
anywhere."

**What this project has not been able to observe directly**: the exact
on-screen sequence of Sparkle's own "Update Available" / "Installing
Update…" UI clicking through end to end against a real, non-placeholder
feed host, since that needs a genuine second machine or a long-lived hosted
feed rather than a throwaway local server. What's verified above is the
mechanism Sparkle uses and its documented, source-confirmed behaviour with
an unnotarised app, which is what determines whether the install succeeds
or Gatekeeper blocks it - not a guess about what the dialog will say.

A discovered, unrelated bug fixed alongside this: hardened runtime's Library
Validation refuses to load `Sparkle.framework` at all when the app is
signed only with a self-signed identity (no Apple-issued Team ID means
dyld cannot confirm the app and the framework belong to "the same team",
even when `codesign --deep` signed both with the identical certificate).
Without `com.apple.security.cs.disable-library-validation` in
`Clip.entitlements`, a `package.sh`-built Release binary fails to launch at
all with `Library not loaded: @rpath/Sparkle.framework/... different Team
IDs` - this was reproduced, root-caused against Apple's own Library
Validation requirement, fixed, and re-verified (clean launch, twice, with
the fix) as part of this pass. This is a one-time entitlement, not something
that recurs.

## Known limitation of this app shape

Clip is `LSUIElement` (no Dock icon, no standard App menu), so unlike a
typical Sparkle integration there is no existing "Check for Updates…" menu
item for Sparkle to wire itself into automatically. That is why this
project added its own entry point in Settings > General > Updates rather
than relying on Sparkle's usual auto-wired menu item.
