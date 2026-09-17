#!/usr/bin/env bash
# Clip - build a distributable .dmg
#
#   ./package.sh              build, sign, package
#   ./package.sh --install    also install it to /Applications
#
# Signing: Clip is free and open source, and is not notarised. Notarisation
# needs a paid ($99/year) Apple Developer ID Application certificate, and
# this project does not have one - that is a permanent decision, not a
# placeholder waiting for one. This is not a degraded state: it is how a
# free, source-available app is supposed to ship outside the App Store.
#
# What actually matters day to day is not notarisation, it is a STABLE
# identity. macOS binds a Keychain grant to the exact signature that asked
# for it, so an identity that changes between builds makes macOS re-ask for
# Keychain access on every single build - and Clip runs as a menu-bar agent
# with no window to answer that prompt, so it would just hang. A self-signed
# identity fixes this completely: same signature every build, one Keychain
# grant, forever. Gatekeeper still warns on first open (right-click, Open,
# or strip the quarantine attribute - see the DMG's own "Read me first.txt"
# and README.md's Install section for the exact steps and the reasoning);
# that one-time warning is the entire cost of skipping the paid certificate.
#
# This script finds "Clip Local Signing" in the keychain and reuses it. If
# it is missing, it creates it once, the same way every time (see
# docs/LOCAL-SIGNING.md for the manual version of the same recipe, and how
# to remove it). Nothing here ever looks for or prefers a Developer ID -
# there is no such branch to fall out of.
#
# The hardened runtime is enabled.
#
# This script never deletes anything. A previous install is moved aside, so a
# bad build can always be walked back.

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=retention.sh
source ./retention.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Clip/Info.plist 2>/dev/null || true)"
# Never let an empty version reach a path.
if [ -z "$VERSION" ]; then VERSION="2.0"; fi

# Built OUTSIDE the repo, in real /tmp rather than under this folder.
# The repo lives under Google Drive's CloudStorage mount, whose File
# Provider extension stamps every synced item with `com.apple.provenance`
# and `com.apple.FinderInfo` extended attributes - and re-applies them
# faster than a one-time `xattr -c` can strip them, which is not
# stoppable from a build script. `codesign --deep` refuses to sign
# anything carrying those attributes ("resource fork, Finder information,
# or similar detritus not allowed"), and Sparkle.framework's own bundle
# structure (Versions/Current, nested Resources) is exactly the kind of
# nested content that trips over it once this repo is under Drive. Building
# in real, non-synced /tmp sidesteps the whole problem rather than fighting
# a filesystem that reattaches its own metadata.
# A stable path, not a fresh `mktemp -d` per run, so an ordinary Release
# rebuild stays incremental the same way it always has.
BUILD_DIR="/tmp/clip-release-build"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/Build/Products/Release/Clip.app"
STAGE="$(mktemp -d)/Clip"
DMG="dist/Clip-$VERSION.dmg"

echo "▸ Generating the Xcode project"
python3 regen-project.py >/dev/null

echo "▸ Building Clip $VERSION (Release)"
xcodebuild -project Clip.xcodeproj -scheme Clip -configuration Release \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build >/dev/null

# The test harness must not be in what ships. Checked, not trusted: it is
# compiled out because Release does not define CLIP_TESTING, and if that ever
# regresses this stops the release rather than shipping a remote control over
# the user's clipboard history.
if nm -a "$APP/Contents/MacOS/Clip" 2>/dev/null | grep -qi qabridge; then
  echo "✗ REFUSING TO PACKAGE: the QA bridge is present in the Release binary." >&2
  exit 1
fi
echo "  the QA bridge is absent from the binary, as it must be"

# The one identity this project ever signs with. `|| true` matters: with
# `set -e`, grep finding nothing would abort the whole script, which is the
# ordinary case the very first time this runs on a machine.
LOCAL_IDENTITY_NAME="Clip Local Signing"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "$LOCAL_IDENTITY_NAME" | head -1 \
            | sed 's/.*"\(.*\)"/\1/' || true)"

if [ -n "$IDENTITY" ]; then
  echo "▸ Reusing the existing '$LOCAL_IDENTITY_NAME' identity"
else
  # Idempotent, one-time setup: the same recipe docs/LOCAL-SIGNING.md gives
  # for doing this by hand, run automatically instead of leaving it as a
  # manual step someone forgets. A fresh identity per build is the actual
  # bug this whole approach exists to avoid - see the top-of-file comment -
  # so this only ever runs once per machine, checked first every time.
  echo "▸ No '$LOCAL_IDENTITY_NAME' identity found. Creating it now (one-time)."
  CERT_DIR="$(mktemp -d)"
  cat > "$CERT_DIR/clip-cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $LOCAL_IDENTITY_NAME
O = Clip
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
1.2.840.113635.100.6.1.13 = critical,DER:0500
EOF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$CERT_DIR/clip-cert.cnf" \
    -keyout "$CERT_DIR/clip-signing.key" -out "$CERT_DIR/clip-signing.crt" >/dev/null 2>&1
  openssl pkcs12 -export -out "$CERT_DIR/clip-signing.p12" \
    -inkey "$CERT_DIR/clip-signing.key" -in "$CERT_DIR/clip-signing.crt" \
    -passout pass: -name "$LOCAL_IDENTITY_NAME"
  echo "  Importing into the login keychain (macOS may ask for your password once)"
  security import "$CERT_DIR/clip-signing.p12" -k ~/Library/Keychains/login.keychain-db \
    -P "" -T /usr/bin/codesign
  echo "  Trusting it for code signing (macOS may ask for your admin password once)"
  sudo security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$CERT_DIR/clip-signing.crt"
  rm -rf "$CERT_DIR"
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
              | grep "$LOCAL_IDENTITY_NAME" | head -1 \
              | sed 's/.*"\(.*\)"/\1/' || true)"
  if [ -z "$IDENTITY" ]; then
    echo "✗ Created '$LOCAL_IDENTITY_NAME' but codesign still cannot find it." >&2
    echo "  Run: security find-identity -v -p codesigning" >&2
    echo "  and see docs/LOCAL-SIGNING.md to finish it by hand." >&2
    exit 1
  fi
  echo "  Created and trusted '$LOCAL_IDENTITY_NAME'. Every future build on"
  echo "  this Mac reuses it - nothing about this step runs again."
fi

echo "▸ Signing with: $IDENTITY"
SIGN_AS="$IDENTITY"

# Sparkle's embedded framework (Contents/Frameworks/Sparkle.framework)
# carries a `com.apple.provenance` extended attribute on files inside it,
# left by however Xcode staged the Swift Package Manager checkout into the
# build. `codesign --deep` refuses to sign anything carrying it -
# "resource fork, Finder information, or similar detritus not allowed" -
# even though the attribute has nothing to do with the actual code. Stripped
# recursively before signing; it is build metadata, not app behaviour, so
# there is nothing here for a later build to regenerate incorrectly.
xattr -cr "$APP"

codesign --force --deep --options runtime \
         --entitlements Clip/Clip.entitlements \
         --sign "$SIGN_AS" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
codesign -d --verbose=2 "$APP" 2>&1 | grep -i "flags" | sed 's/^/  /' || true

echo "▸ Staging"
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Install or Update Clip.command" <<'INSTALLER'
#!/bin/sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== Installing / Updating Clip ==="

# 1. End any running copy of Clip
osascript -e 'quit app "Clip"' 2>/dev/null || true
for _ in 1 2 3 4 5; do
  pgrep -x Clip >/dev/null 2>&1 || break
  sleep 0.3
done
pkill -x Clip 2>/dev/null || true

# 2. Reset previous Accessibility permissions so macOS prompts fresh for the new signature
echo "▸ Resetting previous Accessibility permissions..."
BUNDLE="com.clip.app"
tccutil reset Accessibility "$BUNDLE" 2>&1 || true

# 3. Back up previous install if present
TARGET="/Applications/Clip.app"
if [ -d "$TARGET" ]; then
  BACKUP="$HOME/Library/Application Support/Clip/previous-versions/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP"
  mv "$TARGET" "$BACKUP/Clip.app"
  echo "▸ Moved previous version to: $BACKUP/Clip.app"
fi

# 4. Copy newly built Clip.app to /Applications
echo "▸ Installing Clip to /Applications..."
cp -R "$DIR/Clip.app" /Applications/

# 5. Remove quarantine attribute
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# 6. Launch Clip and open Accessibility settings
echo "▸ Launching Clip..."
open -a "$TARGET"
sleep 1
echo "▸ Opening Accessibility settings to grant new permissions..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

echo ""
echo "✔ Done! Clip is running and ready for you to switch ON in Accessibility settings."
INSTALLER
chmod +x "$STAGE/Install or Update Clip.command"

cat > "$STAGE/Read me first.txt" <<'NOTE'
Clip

To install or update:
  - Recommended: double-click "Install or Update Clip.command".
    It replaces /Applications/Clip.app, resets old Accessibility grants,
    launches Clip, and opens Accessibility settings so the new permissions
    take effect immediately.
  - Or manually: drag Clip onto the Applications folder beside it.

The first time you open it, macOS will say it cannot verify the developer.
That is expected: Clip is free and open source, and Apple charges $99 a year
for the Developer ID certificate that would make that warning disappear.
This project has chosen not to pay that fee. It says nothing about whether
the app is safe - it is source-available, so if you would rather not take it
on trust, read the code or build it yourself with build.sh or package.sh.

Two ways to open it anyway, both one-time:
  - Right-click (or Control-click) Clip in Applications, choose Open, then
    confirm in the dialog that appears.
  - Or, in Terminal: xattr -dr com.apple.quarantine /Applications/Clip.app
    then open it normally.

Clip is a menu-bar app. It has no Dock icon by default - look for the
clipboard icon in the menu bar at the top of the screen.

It will ask for Accessibility permission. It needs that to paste into other
apps and to use the global shortcut. Nothing leaves this Mac unless you turn
on sync yourself.

Updating over an older build asks again
  Installing with the "install" option of this build's package script resets
  this Mac's Accessibility permission for Clip before the new copy launches,
  so macOS asks for it fresh. This is expected, and not a sign anything is
  wrong: macOS ties that permission to the exact build that was signed, so a
  System Settings switch that looks ON can belong to a build this one just
  replaced. Accept the prompt once, the same as on a first install.

Where Clip keeps your data
  ~/Library/Application Support/Clip - your clipboard history, themes, tabs
  and shortcuts, in one file (clip.sqlite). API keys and your sync token live
  in the macOS Keychain, not in that folder.

Updating keeps everything
  Installing a newer build over an older one, from this DMG or a fresh
  download, does not touch your history. Clip backs up its own database
  before it changes anything, checks it is readable on every launch, and
  restores from that backup on its own if the file is ever found damaged.

Uninstalling
  Deleting Clip.app removes the app only. Your history, themes and settings
  stay in ~/Library/Application Support/Clip, and your API keys and sync
  token stay in the Keychain (search Keychain Access for "Clip" to remove
  them by hand). To remove everything: delete Clip.app, then that folder,
  then the Keychain items. Reinstalling Clip afterwards starts fresh; a
  reinstall WITHOUT deleting that folder first picks up right where you left
  off.
NOTE

echo "▸ Building $DMG"
hdiutil create -volname "Clip $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  -quiet "$DMG"
SIZE="$(du -h "$DMG" | cut -f1)"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA  $(basename "$DMG")" > "$DMG.sha256"

echo ""
echo "  $DMG  ($SIZE)"
echo "  sha256  $SHA"

# --- No notarisation, by policy -------------------------------------------
#
# This DMG is not notarised, and there is no code path in this script that
# tries. Notarisation needs a paid ($99/year) Apple Developer ID Application
# certificate; this project does not have one, permanently, not as a stage
# it is waiting to reach. Sparkle's own EdDSA signature (see
# docs/UPDATES.md) is the real integrity control for updates - Apple
# notarisation is a separate, additional Gatekeeper convenience this project
# has chosen not to pay for. The DMG above opens fully with the one-time
# right-click-Open step this script's Read-me explains.
echo "▸ Not notarised: this project ships without a paid Developer ID, on"
echo "  purpose, permanently. See the DMG's Read me first.txt for what that"
echo "  means on first open."

if [ "${1:-}" = "--install" ]; then
  echo ""
  echo "▸ Installing to /Applications"
  # NOT -quiet: that suppresses the very line the mount point is read from,
  # which left MOUNT empty and the install silently doing nothing.
  MOUNT="$(hdiutil attach "$DMG" -nobrowse | awk -F'\t' '/Volumes/ {print $NF}' | tail -1)"
  if [ -z "$MOUNT" ] || [ ! -d "$MOUNT/Clip.app" ]; then
    echo "✗ could not mount $DMG" >&2
    exit 1
  fi
  echo "  mounted at $MOUNT"
  # Quit the running copy, and MAKE SURE IT IS GONE.
  #
  # `quit app "Clip"` is a polite request an agent app can decline, and it did:
  # the old process kept running, the new one launched beside it, and the user
  # was clicking a menu-bar icon that belonged to the old build. "I don't see
  # any change" after a successful install was exactly this, and nothing about
  # the install said otherwise.
  osascript -e 'quit app "Clip"' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Clip >/dev/null 2>&1 || break
    sleep 0.4
  done
  if pgrep -x Clip >/dev/null 2>&1; then
    echo "  the running copy did not quit on request; ending it"
    pkill -x Clip 2>/dev/null || true
    sleep 1
  fi
  if pgrep -x Clip >/dev/null 2>&1; then
    echo "✗ REFUSING TO INSTALL: a copy of Clip is still running." >&2
    echo "  Installing under it would leave the old build serving the menu bar." >&2
    exit 1
  fi
  echo "  no copy of Clip is running"
  # "Each time we install clip, make sure to delete the last accessibility
  # entry so you refresh it to the new code." macOS ties the Accessibility
  # grant to the code signature, and every build here is signed afresh - so
  # System Settings can show Clip switched ON while AXIsProcessTrusted()
  # says no, because that grant belongs to a build this one is about to
  # replace. Run now, after the old copy has confirmed quit and before the
  # new one launches: no admin rights needed for our own bundle, and the
  # very first launch below asks for the permission fresh.
  echo "  resetting the Accessibility grant so it is asked for fresh"
  tccutil reset Accessibility com.clip.app 2>&1 | sed 's/^/    /' || true
  echo "  tccutil reset done: com.clip.app will ask for Accessibility again"
  # The previous install is MOVED ASIDE, never destroyed. If this build turns
  # out to be worse than the one it replaces, the old one is still there.
  if [ -d "/Applications/Clip.app/Contents/MacOS" ]; then
    BACKUP="$HOME/Library/Application Support/Clip/previous-versions/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP"
    mv "/Applications/Clip.app" "$BACKUP/Clip.app"
    echo "  previous version kept at: $BACKUP/Clip.app"
  fi
  # Retention (M3.7): keep the newest 2 previous-versions entries. Older
  # ones are MOVED into Reclaimed-<ts>, never removed with rm - eighteen
  # copies and 168 MB was the state this was written to fix. The algorithm
  # lives in retention.sh, sourced above, so it can be proved against a
  # throwaway temp directory (QA gate H9) as well as run for real here.
  retain_previous_versions \
    "$HOME/Library/Application Support/Clip/previous-versions" \
    "$HOME/Library/Application Support/Clip" 2
  cp -R "$MOUNT/Clip.app" /Applications/
  hdiutil detach "$MOUNT" -quiet
  # A downloaded DMG carries a quarantine flag; one built here does not, but
  # clear it anyway so the installed copy behaves the same either way.
  xattr -dr com.apple.quarantine /Applications/Clip.app 2>/dev/null || true
  echo "  installed: /Applications/Clip.app"
  open -a /Applications/Clip.app
  sleep 1
  echo "  opening Accessibility settings so the new permissions can be confirmed"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
  sleep 2
  # Say which build is actually serving the menu bar now. An install that
  # reports success while an older process owns the icon is the one failure
  # this whole block exists to prevent, so it is verified rather than assumed.
  RUNNING="$(pgrep -x Clip | wc -l | tr -d ' ')"
  if [ "$RUNNING" = "1" ]; then
    echo "  running: the copy just installed (pid $(pgrep -x Clip))"
  else
    echo "  ⚠ $RUNNING copies of Clip are running; quit them all and reopen" >&2
  fi
  echo "  launched. Look for the clipboard icon in the menu bar."
fi
