<?php
/**
 * Spaces, tokens, devices and records.
 *
 * The one rule the whole file exists to keep: a space id is derived from the
 * bearer token and never read from the request body. A client has no way to
 * name a space it does not hold the token for, so it cannot ask for one.
 */

const GRACE_DAYS = 30;

// Crockford's base32: no I, L, O or U, so a token read off a screen or repeated
// out loud cannot be mistyped into a different valid token.
const TOKEN_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const TOKEN_GROUPS = 5;
const TOKEN_GROUP_LEN = 5;      // 25 symbols = 125 bits

function make_token(): string
{
    $body = '';
    $max = strlen(TOKEN_ALPHABET) - 1;
    for ($i = 0; $i < TOKEN_GROUPS * TOKEN_GROUP_LEN; $i++) {
        $body .= TOKEN_ALPHABET[random_int(0, $max)];
    }
    return 'CLIP-' . implode('-', str_split($body, TOKEN_GROUP_LEN));
}

/**
 * Accepts a token however it was pasted.
 *
 * People paste with the dashes, without them, in lower case, with a stray space
 * from a chat client. Those are the same token, and refusing them would be
 * refusing the user's own key on a technicality.
 */
function normalise_token(string $token): string
{
    $cleaned = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $token));
    if (strpos($cleaned, 'CLIP') === 0) {
        $cleaned = substr($cleaned, 4);
    }
    return $cleaned;
}

function hash_token(string $token): string
{
    return hash('sha256', normalise_token($token));
}

/** Resolves the bearer token to a space, refusing one past its purge date. */
function current_space(): ?array
{
    $token = bearer_token();
    if (normalise_token($token) === '') {
        return null;
    }
    $statement = db()->prepare(
        'SELECT s.* FROM tokens t JOIN spaces s ON s.id = t.space_id
         WHERE t.token_hash = ?'
    );
    $statement->execute([hash_token($token)]);
    $row = $statement->fetch();
    if (!$row) {
        return null;
    }
    if ($row['purge_at'] !== null && (float)$row['purge_at'] <= now()) {
        return null;
    }
    return $row;
}

function require_space(): array
{
    $space = current_space();
    if (!$space) {
        fail(401, 'That sync token is not valid. Check it and paste it again.');
    }
    return $space;
}

function space_summary(string $spaceID): array
{
    $pdo = db();

    $statement = $pdo->prepare('SELECT * FROM spaces WHERE id = ?');
    $statement->execute([$spaceID]);
    $row = $statement->fetch();

    $statement = $pdo->prepare('SELECT COUNT(*) FROM devices WHERE space_id = ?');
    $statement->execute([$spaceID]);
    $devices = (int)$statement->fetchColumn();

    // Items only. Settings ride the same records table as their own entity, so
    // counting every row made the app report "Items in the account: 101" for a
    // library of 100 clips. This number is shown to a person.
    //
    // Rows with seq = 0 are excluded because seq = 0 is exactly what marks a
    // record no device can pull: the pull query asks for `seq > since` and
    // `since` starts at 0. A multipart record carries seq = 0 until its last
    // part arrives, so a large item whose upload was interrupted would
    // otherwise be counted here for ever and leave the server reporting more
    // items than any client can ever hold.
    $statement = $pdo->prepare(
        'SELECT COUNT(*) FROM records
         WHERE space_id = ? AND deleted = 0 AND entity = ? AND seq > 0');
    $statement->execute([$spaceID, 'item']);
    $items = (int)$statement->fetchColumn();

    return [
        'id'      => $spaceID,
        'shared'  => (bool)$row['shared'],
        'devices' => $devices,
        'items'   => $items,
        'createdAt' => iso((float)$row['created_at']),
        'deletionRequestedAt' => $row['deletion_requested_at'] !== null
            ? iso((float)$row['deletion_requested_at']) : null,
    ];
}

/**
 * The next sequence number for a space.
 *
 * `LAST_INSERT_ID(expr)` makes the increment and the read one statement, so two
 * devices syncing at the same moment cannot be handed the same number - which
 * would make one of them invisible to the other's cursor for good.
 */
function next_seq(string $spaceID): int
{
    $pdo = db();
    $statement = $pdo->prepare(
        'INSERT INTO counters (space_id, seq) VALUES (?, LAST_INSERT_ID(1))
         ON DUPLICATE KEY UPDATE seq = LAST_INSERT_ID(seq + 1)'
    );
    $statement->execute([$spaceID]);
    return (int)$pdo->lastInsertId();
}

function touch_device(string $spaceID, string $deviceID, string $name): void
{
    $statement = db()->prepare(
        'INSERT INTO devices (space_id, device_id, name, last_seen) VALUES (?,?,?,?)
         ON DUPLICATE KEY UPDATE name = VALUES(name), last_seen = VALUES(last_seen)'
    );
    $statement->execute([$spaceID, $deviceID, $name, now()]);
}

/**
 * Runs purge_expired() at most once per hour, across requests.
 *
 * `/sync` is called far more often than `/token/create`, so calling the sweep
 * unconditionally here would mean a full scan of `spaces` on every sync. Each
 * PHP-FPM/CGI request on shared hosting is its own short-lived process, so an
 * in-memory "last run" flag would reset every time; the hour marker instead
 * lives in the `throttle` table (already used for rate limiting), keyed so it
 * can never collide with a real IP or token bucket, and `INSERT IGNORE` makes
 * "am I first this hour" atomic: exactly one request per hour wins the race
 * and actually pays for the scan.
 */
function maybe_purge_expired(): void
{
    $pdo = db();
    $window = (int)floor(time() / 3600);
    $statement = $pdo->prepare(
        'INSERT IGNORE INTO throttle (ip, window, hits) VALUES (?, ?, 1)'
    );
    $statement->execute(['__purge_marker__', $window]);
    if ($statement->rowCount() > 0) {
        purge_expired();
    }
}

/** Removes spaces whose grace period has elapsed. */
function purge_expired(): int
{
    $pdo = db();
    $statement = $pdo->prepare('SELECT id FROM spaces WHERE purge_at IS NOT NULL AND purge_at <= ?');
    $statement->execute([now()]);
    $ids = $statement->fetchAll(PDO::FETCH_COLUMN);

    foreach ($ids as $id) {
        // The foreign keys cascade, but counters has none, so it goes by hand.
        $pdo->prepare('DELETE FROM counters WHERE space_id = ?')->execute([$id]);
        $pdo->prepare('DELETE FROM spaces WHERE id = ?')->execute([$id]);
    }
    return count($ids);
}

/**
 * A rough per-IP limit on creating spaces.
 *
 * `/token/create` is unauthenticated by design - requiring an identity to get an
 * empty pool would put back the sign-in step this whole design removes - which
 * makes it the one endpoint someone can hammer for free.
 */
function throttle_or_fail(string $bucket, int $perHour): void
{
    $pdo = db();
    $window = (int)floor(time() / 3600);
    $ip = client_ip();

    $pdo->prepare(
        'INSERT INTO throttle (ip, window, hits) VALUES (?,?,1)
         ON DUPLICATE KEY UPDATE hits = hits + 1'
    )->execute([$bucket . ':' . $ip, $window]);

    $statement = $pdo->prepare('SELECT hits FROM throttle WHERE ip = ? AND window = ?');
    $statement->execute([$bucket . ':' . $ip, $window]);
    if ((int)$statement->fetchColumn() > $perHour) {
        fail(429, 'Too many sync tokens created from this address. Try again later.');
    }

    // Rows older than a day are of no further use to anyone.
    $pdo->prepare('DELETE FROM throttle WHERE window < ?')->execute([$window - 24]);
}

/**
 * L3-3: a per-token rate limit on `/sync`.
 *
 * `/sync` is authenticated, unlike `/token/create`, so the risk here is not a
 * stranger hammering an open door - it is one client (or a bug in one) doing
 * real database work, a write transaction plus a read, on every call, on
 * shared hosting. Keyed by space id rather than IP, because the token - not
 * the network address - is what actually identifies the caller, and because
 * punishing an IP would also punish every other space behind the same NAT.
 *
 * The default is tuned against the client's own cadence: it syncs on a
 * 60-second timer plus one immediate sync per local change, so a real client
 * session sits far under any per-minute cap worth setting; only a runaway
 * retry loop or a hostile caller reaches it.
 */
function throttle_sync_or_fail(string $spaceID, int $perMinute): void
{
    $pdo = db();
    $window = (int)floor(time() / 60);
    $key = 'sync:' . $spaceID;

    $pdo->prepare(
        'INSERT INTO throttle (ip, window, hits) VALUES (?,?,1)
         ON DUPLICATE KEY UPDATE hits = hits + 1'
    )->execute([$key, $window]);

    $statement = $pdo->prepare('SELECT hits FROM throttle WHERE ip = ? AND window = ?');
    $statement->execute([$key, $window]);
    $hits = (int)$statement->fetchColumn();

    if ($hits > $perMinute) {
        $secondsLeftInWindow = 60 - (time() % 60);
        fail_too_many(
            'Too many sync requests for this token. Slow down and try again shortly.',
            $secondsLeftInWindow
        );
    }
}

/**
 * T1-M3: a per-token, per-endpoint rate limit for the token-authenticated
 * endpoints that had none: token/claim, token/sharing, token/forget,
 * auth/google/forget, space/delete and space/delete/cancel.
 *
 * Same shape as throttle_sync_or_fail (keyed by space id, not IP, because the
 * token is the identity that matters), generalised with a bucket name so each
 * endpoint gets its own counter in the same shared `throttle` table rather
 * than fighting over one row per space. Called before any DB write so a
 * throttled call never mutates state.
 */
function throttle_token_or_fail(string $spaceID, string $bucket, int $perMinute): void
{
    $pdo = db();
    $window = (int)floor(time() / 60);
    $key = $bucket . ':' . $spaceID;

    $pdo->prepare(
        'INSERT INTO throttle (ip, window, hits) VALUES (?,?,1)
         ON DUPLICATE KEY UPDATE hits = hits + 1'
    )->execute([$key, $window]);

    $statement = $pdo->prepare('SELECT hits FROM throttle WHERE ip = ? AND window = ?');
    $statement->execute([$key, $window]);
    $hits = (int)$statement->fetchColumn();

    if ($hits > $perMinute) {
        $secondsLeftInWindow = 60 - (time() % 60);
        fail_too_many(
            'Too many requests for this sync token. Slow down and try again shortly.',
            $secondsLeftInWindow
        );
    }
}
