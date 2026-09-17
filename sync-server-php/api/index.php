<?php
/**
 * Clip sync service.
 *
 * The same HTTP API the local Python service speaks, reimplemented for PHP and
 * MySQL because GoDaddy shared hosting runs those and will never run a
 * long-lived Python process. Switching between them is a base-URL change in the
 * app and nothing else.
 *
 * There are no accounts and no sign-in. A *space* is a pool of synced data
 * addressed by one token, and holding the token is the whole of the
 * authorisation. That removes passwords, OAuth applications, email verification
 * and account recovery - every one of which was a way for sync to fail before it
 * ever synced anything - and in exchange the token has to be treated like a key,
 * because it is one.
 *
 * Security properties this file is responsible for:
 *   - Only sha256(token) is stored. The database alone syncs nothing.
 *   - Every row is scoped to a space id taken from the token, never from the
 *     body. A client cannot name another space.
 *   - A space can be locked, after which no new device may claim its token.
 *   - Deletion is two-phase with a 30-day grace period, so it is recoverable.
 *
 * On storage limits: there are none here on purpose. See schema.sql for the one
 * that bites silently (column type), and the client for the one that bites
 * loudly (request size, handled by chunking).
 */

declare(strict_types=1);

require __DIR__ . '/lib/http.php';
require __DIR__ . '/lib/db.php';
require __DIR__ . '/lib/store.php';
require __DIR__ . '/lib/google.php';

$configPath = getenv('CLIP_CONFIG');
if (!$configPath || !is_readable($configPath)) {
    $configPath = __DIR__ . '/config.php';
}
$config = require $configPath;

// A token is a bearer credential: over plain HTTP it is readable in transit.
if (!empty($config['require_https'])) {
    $https = ($_SERVER['HTTPS'] ?? '') !== '' && ($_SERVER['HTTPS'] ?? 'off') !== 'off';
    $forwarded = strtolower((string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '')) === 'https';
    if (!$https && !$forwarded) {
        fail(400, 'Sync requires HTTPS.');
    }
}

$route  = route_path();
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$body   = $method === 'POST' ? request_body() : [];

/**
 * The path the client asked for, whatever the web server did to it on the way.
 *
 * Three shapes have to give the same answer, because a router that handles only
 * the shape you developed against fails as a 404 on the *live* server after
 * passing every local test:
 *
 *   1. Apache + mod_rewrite:  REQUEST_URI /clipassets/api/token/create,
 *      SCRIPT_NAME /clipassets/api/index.php  -> strip the script's directory.
 *   2. No mod_rewrite:        .../index.php/token/create, PATH_INFO carries it.
 *   3. PHP's built-in server: SCRIPT_NAME is the *requested* path, not the
 *      script - so taking its dirname turned /token/create into /create.
 *
 * The guard is that SCRIPT_NAME is only treated as a script when it looks like
 * one. Anything else and there is no prefix to remove.
 */
function route_path(): string
{
    $path = (string)($_SERVER['PATH_INFO'] ?? '');
    if ($path === '') {
        $uri = parse_url((string)($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH) ?: '/';

        $script = (string)($_SERVER['SCRIPT_NAME'] ?? '');
        if (substr($script, -4) === '.php') {
            $base = rtrim(str_replace('\\', '/', dirname($script)), '/');
            if ($base !== '' && $base !== '.' && strpos($uri, $base) === 0) {
                $uri = substr($uri, strlen($base));
            }
        }
        $path = $uri;
    }
    $path = '/' . trim($path, '/');
    // index.php can still be in the path when mod_rewrite is unavailable.
    $path = preg_replace('#^/index\.php#', '', $path);
    return $path === '' ? '/' : $path;
}

if ($method === 'GET') {
    switch ($route) {
        case '/':
        case '/health':
            send_json(200, ['ok' => true, 'service' => 'clip-sync', 'storage' => 'unlimited']);
        case '/space':
            $space = require_space();
            send_json(200, ['space' => space_summary($space['id'])]);
        case '/token/devices':
            // Which Macs this token has actually been used from. The count in
            // space_summary said "2 Macs" and nothing more, which is unusable
            // when one of the two is a Mac that no longer exists.
            $space = require_space();
            $statement = db()->prepare(
                'SELECT device_id, name, last_seen FROM devices
                  WHERE space_id = ? ORDER BY last_seen DESC'
            );
            $statement->execute([$space['id']]);
            $devices = [];
            foreach ($statement->fetchAll() as $row) {
                $devices[] = [
                    'deviceID' => (string)$row['device_id'],
                    'name'     => (string)($row['name'] ?? 'Mac'),
                    'lastSeen' => (float)$row['last_seen'],
                ];
            }
            send_json(200, ['devices' => $devices]);
        default:
            fail(404, 'Unknown endpoint.');
    }
}

if ($method !== 'POST') {
    fail(405, 'Use POST.');
}

switch ($route) {
    case '/token/create':   token_create($body, $config);   break;
    case '/auth/google':    auth_google($body, $config);    break;
    case '/auth/google/forget': auth_google_forget($body);  break;
    case '/token/claim':    token_claim($body);             break;
    case '/token/sharing':  token_sharing($body);           break;
    case '/token/forget':   token_forget($body, $config);   break;
    case '/sync':           sync_records($body, $config);   break;
    case '/space/delete':   space_delete();                 break;
    case '/space/delete/cancel': space_delete_cancel();     break;
    default: fail(404, 'Unknown endpoint.');
}

// ---------------------------------------------------------------- tokens

/**
 * Mints a new, empty space and the only token that reaches it.
 *
 * The token is returned once, here, and never again: the server keeps only its
 * hash, so there is no "email me my token" and there cannot be one.
 */
function token_create(array $body, array $config): void
{
    throttle_or_fail('create', (int)($config['tokens_per_hour'] ?? 20));
    purge_expired();

    $pdo = db();
    $token    = make_token();
    $spaceID  = 'space-' . bin2hex(random_bytes(8));
    $deviceID = (string)($body['deviceID'] ?? '');
    $device   = (string)($body['device'] ?? 'Mac');
    // A request that does not say which Mac it is used to get an id invented
    // here. That id belonged to nothing: the app never learned it, never sent
    // it again, and the row stayed for ever as a Mac the owner did not
    // recognise. An unidentified request is refused instead.
    if ($deviceID === '') {
        fail(400, 'The request did not identify this device.');
    }

    $pdo->beginTransaction();
    try {
        $pdo->prepare('INSERT INTO spaces (id, created_at, shared) VALUES (?,?,1)')
            ->execute([$spaceID, now()]);
        $pdo->prepare('INSERT INTO tokens (token_hash, space_id, created_at) VALUES (?,?,?)')
            ->execute([hash_token($token), $spaceID, now()]);
        touch_device($spaceID, $deviceID, $device);
        $pdo->commit();
    } catch (Throwable $e) {
        $pdo->rollBack();
        error_log('clip-sync: token/create failed: ' . $e->getMessage());
        fail(500, 'Could not create a sync token.');
    }

    send_json(200, ['token' => $token, 'space' => space_summary($spaceID)]);
}

/**
 * Registers this device against the token's space.
 *
 * A locked space accepts only devices it already knows, which is what makes
 * "not shared" mean something: a token that leaks after locking opens nothing.
 */
function token_claim(array $body): void
{
    $space = require_space();
    throttle_token_or_fail($space['id'], 'claim', 20);
    $deviceID = (string)($body['deviceID'] ?? '');
    $device   = (string)($body['device'] ?? 'Mac');
    if ($deviceID === '') {
        fail(400, 'The request did not identify this device.');
    }

    $pdo = db();
    $statement = $pdo->prepare('SELECT 1 FROM devices WHERE space_id = ? AND device_id = ?');
    $statement->execute([$space['id'], $deviceID]);
    $known = (bool)$statement->fetchColumn();

    if (!$known && !(int)$space['shared']) {
        fail(403, 'This sync token is locked to the Macs already using it. '
                . 'Unlock it in Clip on one of those Macs, then try again.');
    }

    // An upgrade changes how this Mac names itself (a random id kept in the
    // app's database became one derived from the hardware). Without this the
    // upgrade would ADD a Mac rather than rename one, and every user's count
    // would jump the day they updated.
    $replaces = (string)($body['replaces'] ?? '');
    if ($replaces !== '' && $replaces !== $deviceID) {
        db()->prepare('DELETE FROM devices WHERE space_id = ? AND device_id = ?')
            ->execute([$space['id'], $replaces]);
    }

    touch_device($space['id'], $deviceID, $device);
    // Coming back cancels a pending deletion: the owner is still here.
    $pdo->prepare('UPDATE spaces SET deletion_requested_at = NULL, purge_at = NULL WHERE id = ?')
        ->execute([$space['id']]);

    send_json(200, ['space' => space_summary($space['id'])]);
}

function token_sharing(array $body): void
{
    $space = require_space();
    throttle_token_or_fail($space['id'], 'sharing', 20);
    db()->prepare('UPDATE spaces SET shared = ? WHERE id = ?')
        ->execute([!empty($body['shared']) ? 1 : 0, $space['id']]);
    send_json(200, ['space' => space_summary($space['id'])]);
}

/**
 * Drops one device from the space. The token still works elsewhere.
 *
 * Signing out a Mac that is NOT the one asking needs the account, not just the
 * token. The token is a shared secret by design - that is the whole model, one
 * secret two Macs - so a token alone must not be able to evict the other Mac.
 * The caller proves the Google account this space belongs to, with a fresh
 * sign-in, and the subject is checked against the space's owner.
 *
 * A space with no Google account behind it (a personal server, a token created
 * before sign-in existed) can only remove the device that is asking.
 */
function token_forget(array $body, array $config): void
{
    $space = require_space();
    throttle_token_or_fail($space['id'], 'forget', 10);
    $target = (string)($body['deviceID'] ?? '');
    if ($target === '') {
        fail(400, 'The request did not say which Mac to sign out.');
    }

    $self = (string)($body['selfDeviceID'] ?? '');
    if ($target !== $self) {
        google_ensure_schema();
        $owner = db()->prepare('SELECT subject FROM google_accounts WHERE space_id = ?');
        $owner->execute([$space['id']]);
        $subject = (string)($owner->fetchColumn() ?: '');
        if ($subject === '') {
            fail(403, 'This token is not linked to a Google account, so only the '
                    . 'Mac you are using can be signed out from here.');
        }
        $proof = google_subject_from_proof($body, $config);
        if ($proof !== $subject) {
            fail(403, 'Sign in with the Google account this sync token belongs to, '
                    . 'then try again.');
        }
    }

    db()->prepare('DELETE FROM devices WHERE space_id = ? AND device_id = ?')
        ->execute([$space['id'], $target]);
    send_json(200, ['ok' => true, 'space' => space_summary($space['id'])]);
}

// ------------------------------------------------------------------ sync

/**
 * Takes a batch of changes and returns a page of them.
 *
 * Both directions are bounded per request, and neither is bounded in total. The
 * client sends its history in byte-budgeted chunks and reads back pages until
 * the cursor stops moving, so an arbitrarily large history syncs through
 * arbitrarily modest limits. What must never appear here is a cap on what a
 * space may *hold*.
 */
function sync_records(array $body, array $config): void
{
    $space    = require_space();
    $spaceID  = $space['id'];          // from the token, never from the body
    $since    = (float)($body['since'] ?? 0);
    $incoming = is_array($body['changes'] ?? null) ? $body['changes'] : [];
    $limit    = (int)($config['page_size'] ?? 200);

    // L3-2: a space a user asked to delete used to sit until someone happened
    // to create a new token. /sync is the far more frequent request, so the
    // sweep runs here too - throttled to once an hour per PHP process rather
    // than on every hit, since it is a full-table scan.
    maybe_purge_expired();

    throttle_sync_or_fail($spaceID, (int)($config['sync_per_minute'] ?? 60));

    $pdo = db();
    if ($incoming) {
        $pdo->beginTransaction();
        try {
            $find = $pdo->prepare(
                'SELECT updated_at FROM records WHERE space_id=? AND entity=? AND id=?'
            );
            $write = $pdo->prepare(
                'INSERT INTO records (space_id, entity, id, updated_at, deleted, payload, seq)
                 VALUES (?,?,?,?,?,?,?)
                 ON DUPLICATE KEY UPDATE
                   updated_at = VALUES(updated_at), deleted = VALUES(deleted),
                   payload = VALUES(payload), seq = VALUES(seq)'
            );
            // Appending rather than replacing is what lets one record arrive
            // across several requests.
            $append = $pdo->prepare(
                'UPDATE records SET payload = CONCAT(payload, ?), seq = ?
                 WHERE space_id=? AND entity=? AND id=?'
            );
            foreach ($incoming as $change) {
                $entity = (string)($change['entity'] ?? '');
                $id     = (string)($change['id'] ?? '');
                if ($entity === '' || $id === '') {
                    continue;
                }
                $updated = (float)($change['updated_at'] ?? now());
                $payload = isset($change['payload']) ? (string)$change['payload'] : null;

                // A record too big for one request arrives in parts.
                //
                // The live server refuses a body over about a megabyte, whatever
                // `post_max_size` says, so without this a single large clip could
                // never sync at all - it would fail identically for ever, which is
                // the one outcome "no limit on stored data" cannot allow.
                $parts = max(1, (int)($change['parts'] ?? 1));
                $part  = max(0, (int)($change['part'] ?? 0));

                if ($parts > 1 && $part > 0) {
                    // Until the last part lands, seq stays 0 so `seq > since`
                    // never matches it: no other device can read a half record.
                    // The last part is what makes the record pullable, so that
                    // is where it is finally given a real sequence number.
                    $isLast = ($part === $parts - 1);
                    $append->execute([$payload, $isLast ? next_seq($spaceID) : 0,
                                      $spaceID, $entity, $id]);
                    continue;
                }

                if ($parts > 1) {
                    // Part 0 of a multipart record always replaces the payload,
                    // deliberately skipping the last-write-wins check below.
                    // The later parts are appended with CONCAT, so if the guard
                    // were allowed to skip this write - which it does whenever
                    // the item is re-sent without its updated_at advancing - the
                    // parts would be concatenated onto the payload that is
                    // already stored and the record would decode as garbage on
                    // every device. Resetting the row here is what makes a
                    // re-upload of a large item idempotent, and it costs nothing
                    // in conflict safety, because the client only chunks a
                    // record it is currently holding in full.
                    $write->execute([
                        $spaceID, $entity, $id, $updated,
                        !empty($change['deleted']) ? 1 : 0, $payload, 0,
                    ]);
                    continue;
                }

                $find->execute([$spaceID, $entity, $id]);
                $existing = $find->fetchColumn();
                // Last write wins; an older copy never overwrites a newer one.
                if ($existing !== false && (float)$existing >= $updated) {
                    continue;
                }
                $write->execute([
                    $spaceID, $entity, $id, $updated,
                    !empty($change['deleted']) ? 1 : 0, $payload,
                    next_seq($spaceID),
                ]);
            }
            $pdo->commit();
        } catch (Throwable $e) {
            $pdo->rollBack();
            error_log('clip-sync: sync write failed: ' . $e->getMessage());
            fail(500, 'The sync service could not store those changes.');
        }
    }

    // One row more than asked for, so "is there another page?" needs no second
    // query and cannot disagree with the rows just sent.
    $statement = $pdo->prepare(
        'SELECT entity, id, updated_at, deleted, payload, seq
         FROM records WHERE space_id = ? AND seq > ?
         ORDER BY seq LIMIT ' . ($limit + 1)
    );
    $statement->execute([$spaceID, $since]);
    $all = $statement->fetchAll();

    $hasMore = count($all) > $limit;
    if ($hasMore) {
        array_pop($all);
    }

    // A page is also bounded by *size*, not only by row count: two hundred large
    // clips would otherwise build a response bigger than the memory limit and
    // fail as a blank 500. One row always goes, however big it is on its own.
    $budget = (int)($config['page_bytes'] ?? 4 * 1024 * 1024);
    $rows = [];
    $bytes = 0;
    foreach ($all as $row) {
        if ($rows && $bytes + strlen((string)$row['payload']) > $budget) {
            $hasMore = true;
            break;
        }
        $bytes += strlen((string)$row['payload']);
        $rows[] = $row;
    }
    $cursor = $rows ? (float)end($rows)['seq'] : $since;

    send_json(200, [
        'cursor'  => (string)$cursor,
        'hasMore' => $hasMore,
        'changes' => array_map(static function (array $row): array {
            return [
                'entity'     => $row['entity'],
                'id'         => $row['id'],
                'updated_at' => (float)$row['updated_at'],
                'deleted'    => (bool)$row['deleted'],
                'payload'    => $row['payload'],
            ];
        }, $rows),
    ]);
}

// -------------------------------------------------------------- deletion

function space_delete(): void
{
    $space = require_space();
    throttle_token_or_fail($space['id'], 'delete', 10);
    $purgeAt = now() + GRACE_DAYS * 86400;
    db()->prepare('UPDATE spaces SET deletion_requested_at = ?, purge_at = ? WHERE id = ?')
        ->execute([now(), $purgeAt, $space['id']]);
    send_json(200, ['ok' => true, 'purgeAt' => iso($purgeAt), 'graceDays' => GRACE_DAYS]);
}

function space_delete_cancel(): void
{
    $space = require_space();
    throttle_token_or_fail($space['id'], 'delete', 10);
    db()->prepare('UPDATE spaces SET deletion_requested_at = NULL, purge_at = NULL WHERE id = ?')
        ->execute([$space['id']]);
    send_json(200, ['ok' => true]);
}
