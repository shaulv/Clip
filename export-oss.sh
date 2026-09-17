#!/usr/bin/env bash
# Clip - produce the open-source folder.
#
#   ./export-oss.sh [destination]      (default: ../clip-oss)
#
# The export is the ONLY route from this working tree to something publishable,
# so the rules about what must not travel live here, in one place, rather than
# in a reviewer's memory:
#
#   - The official sync endpoint is removed. A published fork that shipped it
#     would sync strangers into someone else's database.
#   - The Google OAuth client id is replaced with a placeholder. It is not a
#     secret - Google's own documentation says a desktop client id ships inside
#     the app - but a fork using it would authenticate against this project's
#     Google account, spend its quota, and show its consent screen.
#   - The private notes, credentials and secret folders never enter the copy at
#     all, because the copy is built from an allow-list of what to include, not
#     a deny-list of what to leave out. A deny-list is one forgotten entry away
#     from publishing a password.
#
# Finishes by grepping the result for the things that must not be in it, and
# fails loudly rather than quietly producing a leaky folder.

set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-../clip-oss}"
SRC_ROOT=".."

echo "▸ Building the open-source copy at $DEST"
mkdir -p "$DEST"

# --- allow-list -------------------------------------------------------------
mkdir -p "$DEST/Clip" "$DEST/ClipTests" "$DEST/docs" "$DEST/sync-server" "$DEST/sync-server-php" "$DEST/brand"
rsync -a --delete --delete-excluded \
      --exclude '.DS_Store' \
      Clip/ "$DEST/Clip/"
# regen-project.py walks ClipTests/ for the unit-test target's sources; without
# this a fresh clone's `xcodebuild test` has no ClipTests target to run at all.
rsync -a --delete --delete-excluded \
      --exclude '.DS_Store' \
      ClipTests/ "$DEST/ClipTests/"
cp regen-project.py build.sh package.sh export-oss.sh "$DEST/"
cp qa-probe.py perf-probe.py security-probe.py "$DEST/"
# The reader's first five minutes: what this is, how to license it, how to run
# it, why it is shaped the way it is, what it will not do, and how to add to
# it. A clone with none of these is a clone nobody can safely use or trust.
cp README.md LICENSE START-HERE.md ARCHITECTURE.md SECURITY.md CONTRIBUTING.md "$DEST/"
rsync -a --delete --exclude '.DS_Store' brand/ "$DEST/brand/"
rsync -a --delete --exclude '.DS_Store' "$SRC_ROOT/sync-server/" "$DEST/sync-server/"
# deploy.sh is this project's own upload tooling: it names the author's host
# and reads credentials from a folder that never leaves this Mac. A fork wants
# its own deployment step, not a broken copy of someone else's.
rsync -a --delete --delete-excluded --exclude '.DS_Store' --exclude 'config.php' \
      --exclude 'deploy.sh' --exclude 'restore-from-backup.sh' \
      "$SRC_ROOT/sync-server-php/" "$DEST/sync-server-php/"
# docs/plans/ is this project's own internal lane planning: usernames,
# worktree paths, lane names, agent handoffs. It documents how the maintainer's
# team works, not how the software works, and it is where a contributor's
# real filesystem path or account name would end up public. It never ships.
if [ -d docs ]; then
  rsync -a --delete --delete-excluded --exclude '.DS_Store' --exclude 'plans/' \
        docs/ "$DEST/docs/"
fi

# --- strip what must not be published ---------------------------------------
python3 - "$DEST" <<'PY'
import re, sys, pathlib
dest = pathlib.Path(sys.argv[1])

official = dest / "Clip/Core/OfficialService.swift"
official.write_text('''import Foundation

/// Where "Sign in with Google" syncs to.
///
/// **This is deliberately empty in the open-source tree.**
///
/// The upstream build points this at a service its author runs. Shipping that
/// address in a public repository would mean every fork syncing strangers into
/// somebody else's database, so the export strips it.
///
/// With no address here, Google sign-in reports itself as unavailable and the
/// other two methods are unaffected: "use your own server with this token"
/// works exactly as before, and so does backup import and export. That is the
/// right default. An app that ships with a sync server nobody chose is an app
/// that quietly sends your clipboard somewhere you never agreed to.
///
/// To run your own: stand up `sync-server-php` (see docs/SELF-HOSTING.md), then
/// return the address here. It does not need to be hidden - see the note below.
///
/// ## On hiding the address
///
/// The upstream build stores it XOR-ed so it is not visible to `strings`. That
/// is worth doing and worth being honest about: an address inside a
/// downloadable app cannot be a secret, because the app has to know where to
/// connect and a proxy watching one request recovers it. The address was never
/// the security boundary. Every endpoint requires either a valid sync token or
/// an identity token that Google signed and the server verified. Knowing where
/// the door is does not open it.
enum OfficialService {

    /// nil means "no official service in this build".
    static var url: URL? { nil }

    static let displayName = "Clip's own service"

    static var isConfigured: Bool { url != nil }
}
''')

auth = dest / "Clip/Core/GoogleAuth.swift"
text = auth.read_text()
text = re.sub(r'"\d[\d-]*[a-z0-9]*\.apps\.googleusercontent\.com"',
              '"" /* your-client-id.apps.googleusercontent.com - see docs/GOOGLE-SIGN-IN.md */',
              text)
auth.write_text(text)
# The server README described one specific deployment, by address, and
# pointed at a planning document that is not in this repository.
readme = dest / "sync-server-php/README.md"
if readme.exists():
    lines = []
    for line in readme.read_text().split("\n"):
        if "shaulv" in line:
            if line.startswith("The production sync service"):
                line = ("The sync service. Deploy it to any PHP 8 host with MySQL; "
                        "see `docs/SELF-HOSTING.md`.")
            else:
                continue
        lines.append(line)
    readme.write_text("\n".join(lines))

print("  stripped: official endpoint, Google client id, deployment specifics")
PY

# --- prove it ---------------------------------------------------------------
echo "▸ Checking the copy for things that must not be in it"
FAIL=0
check_absent() {
  local pattern="$1" label="$2"
  local hits
  # --exclude the scanner: it necessarily contains every pattern it searches
  # for, and a check that always trips on itself is a check nobody reads.
  # --exclude build/ and build-*/: Xcode bakes the developer's home path into
  # build artefacts; that directory is gitignored in the published repo so it
  # will never reach the public tree, but it exists on disk during the local run.
  hits="$(grep -rIl --exclude-dir=.git --exclude-dir=build --exclude='export-oss.sh' \
          -e "$pattern" "$DEST" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "  ✗ $label found in:"; echo "$hits" | sed 's/^/      /'; FAIL=1
  else
    echo "  ✓ no $label"
  fi
}
check_absent "shaulv\.com"                     "production host"
check_absent "sxb1plzcpnl505638"               "production FTP hostname"
# The literal check above is beaten by string concatenation - qa-probe.py
# builds the same host as "shaulv" + ".com" so it never appears as one token.
# Catch that shape too rather than trust a single literal pattern.
check_absent '"shaulv" *+ *"\.com"'            "production host (concatenated)"
check_absent "GOCSPX"                          "Google client secret"
# The SHAPE of a real id - digits, a dash, a long alphanumeric - not the
# domain, which the documentation legitimately uses in a placeholder.
check_absent "[0-9]\{6,\}-[a-z0-9]\{20,\}\.apps\.googleusercontent\.com" "real Google client id"
check_absent "CLIP-SYNC-DB-CREDENTIALS"        "credentials note"
check_absent "vainblat"                        "author's name"
check_absent "/Users/shaulvainblat"            "author's real home path"

# No DATA, of any kind. A new user's first launch must create an empty history
# on a default configuration - not inherit one clip, one theme or one connection
# from the machine the export was made on.
check_no_file() {
  local pattern="$1" label="$2"
  local hits
  hits="$(find "$DEST" -path "$DEST/.git" -prune -o -name "$pattern" -print 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "  ✗ $label present:"; echo "$hits" | sed 's/^/      /'; FAIL=1
  else
    echo "  ✓ no $label"
  fi
}
check_no_file "*.sqlite*"   "database"
check_no_file "*.p12"       "signing key"
check_no_file "*.key"       "private key"
check_no_file "test-secrets.json" "test secrets file"
# Docs legitimately explain the clip-sync-secrets/ naming convention by name -
# that is prose, not a leak. What must never happen is the folder itself, or
# any config.php it holds, landing inside the export.
check_no_file "clip-sync-secrets" "secrets folder"

# A configuration that points at somebody's server is data too. The official
# endpoint must be absent by CODE, not merely unset in a file the export
# happened not to copy.
if grep -q "static var url: URL? { nil }" "$DEST/Clip/Core/OfficialService.swift" 2>/dev/null; then
  echo "  ✓ no official endpoint: sign-in is off until a maintainer configures one"
else
  echo "  ✗ OfficialService still names an endpoint"; FAIL=1
fi

# The obfuscated endpoint must be gone as bytes, not just as text.
if grep -rq --exclude='export-oss.sh' "0x33, 0x5A, 0xD3" "$DEST" 2>/dev/null; then
  echo "  ✗ the obfuscated endpoint bytes are still present"; FAIL=1
else
  echo "  ✓ no obfuscated endpoint bytes"
fi

if [ "$FAIL" != "0" ]; then
  echo ""
  echo "✗ EXPORT REFUSED: the copy contains something that must not be published." >&2
  exit 1
fi

echo ""
echo "▸ The open-source copy is at $DEST"
echo "  Verify it builds before publishing:  cd $DEST && ./build.sh"
