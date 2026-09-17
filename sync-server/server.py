#!/usr/bin/env python3
"""Clip sync service.

Deliberately **not part of the Clip app**: its own process, its own database,
its own lifecycle. It speaks the exact HTTP API a hosted deployment will speak,
so moving to a real domain is a base-URL change in the client rather than a
rewrite.

There are no accounts here, and no sign-in. A **sync space** is addressed by one
long token, and holding the token is the whole of the authorisation. That is a
deliberate trade: it removes passwords, OAuth applications, email verification
and account recovery — every one of which was a way for sync to fail before it
ever synced anything — and in exchange the token must be treated like a key,
because it is one.

Security properties this file is responsible for:
  * Only `sha256(token)` is stored. The database alone cannot sync anything.
  * Every row is scoped to a space id taken from the token, never from the
    request body. A client cannot ask for another space's data because it has no
    way to name one.
  * A space can be locked, after which no new device may claim its token. A
    leaked token then reaches nothing.
  * Deletion is two-phase with a 30-day grace period, so it is recoverable.

Run:  python3 server.py [--port 8787] [--db sync.sqlite]
"""

import argparse, hashlib, json, os, secrets, sqlite3, threading, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GRACE_DAYS = 30
DB_LOCK = threading.Lock()
DB_PATH = "sync.sqlite"

# The page bounds the PHP service reads from its config, hard-coded here because
# this service has no config file. They must stay equal to the PHP defaults: the
# client pages until the cursor stops moving, and a client that gets a different
# page shape from the two servers is a client that has to know which one it is
# talking to.
PAGE_SIZE = 200
PAGE_BYTES = 4 * 1024 * 1024

# Crockford's base32: no I, L, O or U, so a token read aloud or copied out of a
# screenshot cannot be mistyped into a different valid token.
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
GROUPS, GROUP_LEN = 5, 5          # 25 symbols = 125 bits


def now() -> float:
    return time.time()


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def connect():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def make_token() -> str:
    body = "".join(
        "".join(secrets.choice(ALPHABET) for _ in range(GROUP_LEN))
        for _ in range(GROUPS)
    )
    return "CLIP-" + "-".join(body[i:i + GROUP_LEN] for i in range(0, len(body), GROUP_LEN))


def normalise(token: str) -> str:
    """Accepts a token however it was pasted.

    People paste with the dashes, without them, in lower case, with a stray
    space from a chat client. All of those are the same token, and refusing them
    would be refusing the user's own key on a technicality.
    """
    cleaned = "".join(c for c in (token or "").upper() if c.isalnum())
    if cleaned.startswith("CLIP"):
        cleaned = cleaned[4:]
    return cleaned


def hash_token(token: str) -> str:
    return hashlib.sha256(normalise(token).encode()).hexdigest()


def init_db():
    with DB_LOCK, connect() as c:
        c.executescript("""
        PRAGMA journal_mode = WAL;

        CREATE TABLE IF NOT EXISTS spaces (
            id                    TEXT PRIMARY KEY,
            created_at            REAL NOT NULL,
            -- 0 locks the space: no device that is not already known may join.
            shared                INTEGER NOT NULL DEFAULT 1,
            deletion_requested_at REAL,
            purge_at              REAL
        );

        -- Only the hash is stored, so the database alone opens nothing.
        CREATE TABLE IF NOT EXISTS tokens (
            token_hash TEXT PRIMARY KEY,
            space_id   TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY(space_id) REFERENCES spaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS devices (
            space_id  TEXT NOT NULL,
            device_id TEXT NOT NULL,
            name      TEXT,
            last_seen REAL NOT NULL,
            PRIMARY KEY (space_id, device_id),
            FOREIGN KEY(space_id) REFERENCES spaces(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS records (
            space_id   TEXT NOT NULL,
            entity     TEXT NOT NULL,
            id         TEXT NOT NULL,
            updated_at REAL NOT NULL,
            deleted    INTEGER NOT NULL DEFAULT 0,
            payload    TEXT,
            seq        INTEGER,
            PRIMARY KEY (space_id, entity, id),
            FOREIGN KEY(space_id) REFERENCES spaces(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS records_seq ON records(space_id, seq);

        CREATE TABLE IF NOT EXISTS counters (
            space_id TEXT PRIMARY KEY,
            seq      INTEGER NOT NULL DEFAULT 0
        );
        """)
        migrate(c)


def migrate(c):
    """Brings a database written by the account-based version forward.

    `CREATE TABLE IF NOT EXISTS` silently does nothing when the table already
    exists, so a schema change never reaches an existing install on its own. The
    previous version of this bug surfaced to the user as "the network connection
    was lost", which named the wrong layer entirely.

    Old accounts become spaces and keep their records. They do not keep a token:
    tokens are only ever stored hashed, so one cannot be recovered — the owner
    creates a new token for the space instead.
    """
    tables = {row["name"] for row in
              c.execute("SELECT name FROM sqlite_master WHERE type='table'")}

    # `records`, `counters` and `tokens` were all keyed by account_id.
    for table in ("records", "counters", "tokens"):
        if table in tables:
            columns = {row["name"] for row in c.execute(f"PRAGMA table_info({table})")}
            if "account_id" in columns and "space_id" not in columns:
                c.execute(f"ALTER TABLE {table} RENAME COLUMN account_id TO space_id")

    if "accounts" in tables:
        for row in c.execute("SELECT id, created_at, deletion_requested_at, purge_at FROM accounts"):
            c.execute("""INSERT OR IGNORE INTO spaces
                         (id, created_at, shared, deletion_requested_at, purge_at)
                         VALUES (?,?,1,?,?)""",
                      (row["id"], row["created_at"],
                       row["deletion_requested_at"], row["purge_at"]))
        # Old tokens named an account and carried password-era assumptions.
        c.execute("DROP TABLE IF EXISTS accounts")
        c.execute("DELETE FROM tokens WHERE space_id NOT IN (SELECT id FROM spaces)")


def next_seq(c, space_id: str) -> int:
    c.execute("INSERT OR IGNORE INTO counters (space_id, seq) VALUES (?, 0)", (space_id,))
    c.execute("UPDATE counters SET seq = seq + 1 WHERE space_id = ?", (space_id,))
    return c.execute("SELECT seq FROM counters WHERE space_id = ?", (space_id,)).fetchone()[0]


def space_summary(c, space_id: str) -> dict:
    row = c.execute("SELECT * FROM spaces WHERE id = ?", (space_id,)).fetchone()
    devices = c.execute("SELECT COUNT(*) FROM devices WHERE space_id = ?", (space_id,)).fetchone()[0]
    # Items only. Settings are synced through the same records table as their
    # own entity, and counting them here made the app tell the user "Items in
    # the account: 101" when they had 100 clips. The number is shown to a
    # person, so it has to mean what it says.
    #
    # Rows with seq = 0 are excluded because seq = 0 is what marks a record no
    # device can pull: the pull query asks for `seq > since` and `since` starts
    # at 0. A multipart record carries seq = 0 until its last part arrives, so
    # an interrupted upload of a large item would otherwise be counted here for
    # ever and leave the server reporting more items than any client can hold.
    items = c.execute("SELECT COUNT(*) FROM records "
                      "WHERE space_id = ? AND deleted = 0 AND entity = 'item' "
                      "AND seq > 0",
                      (space_id,)).fetchone()[0]
    return {
        "id": space_id,
        "shared": bool(row["shared"]),
        "devices": devices,
        "items": items,
        "createdAt": iso(row["created_at"]),
        "deletionRequestedAt": iso(row["deletion_requested_at"]) if row["deletion_requested_at"] else None,
    }


def space_for(token: str):
    """Resolves a token to a space, refusing one past its purge date."""
    if not normalise(token):
        return None
    with DB_LOCK, connect() as c:
        row = c.execute("""
            SELECT s.* FROM tokens t JOIN spaces s ON s.id = t.space_id
            WHERE t.token_hash = ?
        """, (hash_token(token),)).fetchone()
        if row and row["purge_at"] and row["purge_at"] <= now():
            return None
        return row


def purge_expired():
    """Removes spaces whose grace period has elapsed."""
    with DB_LOCK, connect() as c:
        rows = c.execute("SELECT id FROM spaces WHERE purge_at IS NOT NULL AND purge_at <= ?",
                         (now(),)).fetchall()
        for row in rows:
            for table in ("records", "tokens", "counters", "devices"):
                c.execute(f"DELETE FROM {table} WHERE space_id = ?", (row["id"],))
            c.execute("DELETE FROM spaces WHERE id = ?", (row["id"],))
        return len(rows)


class _TooLarge(Exception):
    """Raised after a 413 has already been sent, to stop the handler."""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # quiet by default; the app surfaces failures itself

    # ---------------------------------------------------------------- helpers
    def _send(self, code: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # The same cap the PHP service enforces. The stand-in has to behave like
    # the real one here, or the security suite passes against a server that
    # is not the one that ships.
    MAX_REQUEST_BYTES = 8 * 1024 * 1024

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        if length > self.MAX_REQUEST_BYTES:
            # Read and discard so the connection can be answered rather than
            # reset, which a client reports as "the server went away" instead
            # of "that was too big".
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
            self._send(413, {"error": "That request is too large."})
            raise _TooLarge()
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return {}

    def _token(self):
        auth = self.headers.get("Authorization") or ""
        return auth[7:] if auth.startswith("Bearer ") else ""

    def _require_space(self):
        space = space_for(self._token())
        if not space:
            self._send(401, {"error": "That sync token is not valid. Check it and paste it again."})
            return None
        return space

    # ------------------------------------------------------------------ routes
    def do_GET(self):
        if self.path.startswith("/health"):
            self._send(200, {"ok": True, "service": "clip-sync"})
        elif self.path.startswith("/space"):
            space = self._require_space()
            if space:
                with DB_LOCK, connect() as c:
                    self._send(200, {"space": space_summary(c, space["id"])})
        else:
            self._send(404, {"error": "Unknown endpoint."})

    def do_POST(self):
        route = self.path.split("?")[0]
        try:
            body = self._body()
        except _TooLarge:
            return          # already answered with 413

        if route == "/token/create":
            self._token_create(body)
        elif route == "/token/claim":
            self._token_claim(body)
        elif route == "/token/sharing":
            self._token_sharing(body)
        elif route == "/token/forget":
            self._token_forget(body)
        elif route == "/sync":
            self._sync(body)
        elif route == "/space/delete":
            self._delete()
        elif route == "/space/delete/cancel":
            self._cancel_delete()
        else:
            self._send(404, {"error": "Unknown endpoint."})

    # ------------------------------------------------------------------ tokens
    def _token_create(self, body):
        """Mints a new, empty sync space and the only token that reaches it.

        Unauthenticated on purpose: creating an empty space is not a privileged
        act, and requiring an identity to get one would put back exactly the
        sign-in step this design removes. The token is returned once, here, and
        never again — the server keeps only its hash.
        """
        token = make_token()
        space_id = "space-" + secrets.token_hex(8)
        device = body.get("device") or "Mac"
        device_id = body.get("deviceID") or secrets.token_hex(8)

        with DB_LOCK, connect() as c:
            c.execute("INSERT INTO spaces (id, created_at, shared) VALUES (?,?,1)",
                      (space_id, now()))
            c.execute("INSERT INTO tokens (token_hash, space_id, created_at) VALUES (?,?,?)",
                      (hash_token(token), space_id, now()))
            c.execute("""INSERT INTO devices (space_id, device_id, name, last_seen)
                         VALUES (?,?,?,?)""", (space_id, device_id, device, now()))
            summary = space_summary(c, space_id)

        self._send(200, {"token": token, "space": summary})

    def _token_claim(self, body):
        """Registers this device against the token's space.

        A locked space accepts only devices it already knows, which is what makes
        "not shared" mean something: a token that leaks after locking opens
        nothing.
        """
        space = self._require_space()
        if not space:
            return
        device_id = body.get("deviceID") or ""
        device = body.get("device") or "Mac"
        if not device_id:
            self._send(400, {"error": "The request did not identify this device."})
            return

        with DB_LOCK, connect() as c:
            known = c.execute("SELECT 1 FROM devices WHERE space_id=? AND device_id=?",
                              (space["id"], device_id)).fetchone()
            if not known and not space["shared"]:
                self._send(403, {"error":
                    "This sync token is locked to the Macs already using it. "
                    "Unlock it in Clip on one of those Macs, then try again."})
                return
            c.execute("""INSERT INTO devices (space_id, device_id, name, last_seen)
                         VALUES (?,?,?,?)
                         ON CONFLICT(space_id, device_id) DO UPDATE SET
                           name=excluded.name, last_seen=excluded.last_seen""",
                      (space["id"], device_id, device, now()))
            # Coming back cancels a pending deletion: the owner is still here.
            c.execute("""UPDATE spaces SET deletion_requested_at=NULL, purge_at=NULL
                         WHERE id=?""", (space["id"],))
            summary = space_summary(c, space["id"])

        self._send(200, {"space": summary})

    def _token_sharing(self, body):
        space = self._require_space()
        if not space:
            return
        shared = 1 if body.get("shared") else 0
        with DB_LOCK, connect() as c:
            c.execute("UPDATE spaces SET shared=? WHERE id=?", (shared, space["id"]))
            summary = space_summary(c, space["id"])
        self._send(200, {"space": summary})

    def _token_forget(self, body):
        """Drops one device from the space. The token still works elsewhere."""
        space = self._require_space()
        if not space:
            return
        device_id = body.get("deviceID") or ""
        with DB_LOCK, connect() as c:
            c.execute("DELETE FROM devices WHERE space_id=? AND device_id=?",
                      (space["id"], device_id))
            summary = space_summary(c, space["id"])
        self._send(200, {"ok": True, "space": summary})

    # ------------------------------------------------------------------- sync
    def _sync(self, body):
        space = self._require_space()
        if not space:
            return
        space_id = space["id"]              # from the token, never from the body
        since = float(body.get("since") or 0)
        incoming = body.get("changes") or []

        with DB_LOCK, connect() as c:
            for change in incoming:
                entity = change.get("entity")
                rid = change.get("id")
                if not entity or not rid:
                    continue
                updated = float(change.get("updated_at") or now())
                payload = change.get("payload")

                # A record too big for one request arrives in parts, under the
                # same `parts`/`part` field names the PHP service uses. Without
                # this the parts overwrite each other and a large clip is stored
                # as nothing but its final chunk, which no client can decode.
                parts = max(1, int(change.get("parts") or 1))
                part = max(0, int(change.get("part") or 0))

                if parts > 1 and part > 0:
                    # Appending rather than replacing is what lets one record
                    # arrive across several requests. Until the last part lands,
                    # seq stays 0 so `seq > since` never matches it and no other
                    # device can read half a record; the last part is what gives
                    # the record a real sequence number and makes it pullable.
                    is_last = part == parts - 1
                    c.execute("""UPDATE records
                                 SET payload = COALESCE(payload, '') || ?, seq = ?
                                 WHERE space_id=? AND entity=? AND id=?""",
                              (payload or "",
                               next_seq(c, space_id) if is_last else 0,
                               space_id, entity, rid))
                    continue

                if parts > 1:
                    # Part 0 always replaces the payload, deliberately skipping
                    # the last-write-wins check below. The later parts are
                    # concatenated onto whatever is stored, so if the guard were
                    # allowed to skip this write - which it does whenever the
                    # item is re-sent without its updated_at advancing - the
                    # parts would be appended to the old payload and the record
                    # would decode as garbage everywhere. Resetting the row here
                    # is what makes a re-upload of a large item idempotent.
                    c.execute("""INSERT INTO records (space_id, entity, id, updated_at, deleted, payload, seq)
                                 VALUES (?,?,?,?,?,?,0)
                                 ON CONFLICT(space_id, entity, id) DO UPDATE SET
                                   updated_at=excluded.updated_at, deleted=excluded.deleted,
                                   payload=excluded.payload, seq=excluded.seq""",
                              (space_id, entity, rid, updated,
                               1 if change.get("deleted") else 0, payload))
                    continue

                existing = c.execute("""SELECT updated_at FROM records
                                        WHERE space_id=? AND entity=? AND id=?""",
                                     (space_id, entity, rid)).fetchone()
                # Last write wins; an older copy never overwrites a newer one.
                # A delete is not privileged: a tombstone that is older than the
                # stored row loses like any other older copy, which is the rule
                # the PHP service applies too.
                if existing and existing["updated_at"] >= updated:
                    continue
                seq = next_seq(c, space_id)
                c.execute("""INSERT INTO records (space_id, entity, id, updated_at, deleted, payload, seq)
                             VALUES (?,?,?,?,?,?,?)
                             ON CONFLICT(space_id, entity, id) DO UPDATE SET
                               updated_at=excluded.updated_at, deleted=excluded.deleted,
                               payload=excluded.payload, seq=excluded.seq""",
                          (space_id, entity, rid, updated,
                           1 if change.get("deleted") else 0, payload, seq))

            # One row more than asked for, so "is there another page?" needs no
            # second query and cannot disagree with the rows just sent.
            found = c.execute("""SELECT entity, id, updated_at, deleted, payload, seq
                                 FROM records WHERE space_id=? AND seq > ?
                                 ORDER BY seq LIMIT ?""",
                              (space_id, since, PAGE_SIZE + 1)).fetchall()

        has_more = len(found) > PAGE_SIZE
        if has_more:
            found = found[:PAGE_SIZE]

        # A page is bounded by size as well as by row count: two hundred large
        # clips would otherwise build a response bigger than the process wants
        # to hold. One row always goes, however big it is on its own, or a
        # single oversized record would stall the cursor for ever.
        rows, byte_count = [], 0
        for r in found:
            size = len(r["payload"] or "")
            if rows and byte_count + size > PAGE_BYTES:
                has_more = True
                break
            byte_count += size
            rows.append(r)
        cursor = rows[-1]["seq"] if rows else since

        self._send(200, {
            "cursor": str(cursor),
            "hasMore": has_more,
            "changes": [{"entity": r["entity"], "id": r["id"],
                         "updated_at": r["updated_at"],
                         "deleted": bool(r["deleted"]), "payload": r["payload"]} for r in rows]
        })

    # --------------------------------------------------------------- deletion
    def _delete(self):
        space = self._require_space()
        if not space:
            return
        purge_at = now() + GRACE_DAYS * 86400
        with DB_LOCK, connect() as c:
            c.execute("UPDATE spaces SET deletion_requested_at=?, purge_at=? WHERE id=?",
                      (now(), purge_at, space["id"]))
        self._send(200, {"ok": True, "purgeAt": iso(purge_at), "graceDays": GRACE_DAYS})

    def _cancel_delete(self):
        space = self._require_space()
        if not space:
            return
        with DB_LOCK, connect() as c:
            c.execute("""UPDATE spaces SET deletion_requested_at=NULL, purge_at=NULL
                         WHERE id=?""", (space["id"],))
        self._send(200, {"ok": True})


def main():
    global DB_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--db", default=os.path.join(os.path.dirname(__file__), "sync.sqlite"))
    args = parser.parse_args()

    DB_PATH = args.db
    init_db()
    purged = purge_expired()
    if purged:
        print(f"purged {purged} space(s) past the {GRACE_DAYS}-day grace period")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"clip-sync listening on http://127.0.0.1:{args.port}  db={DB_PATH}")
    server.serve_forever()


if __name__ == "__main__":
    main()
