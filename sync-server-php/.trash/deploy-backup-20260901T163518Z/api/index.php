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
    case '/token/forget':   token_forget($body);            break;
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
    if ($deviceID === '') {
        $deviceID = bin2hex(random_bytes(8));
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

    touch_device($space['id'], $deviceID, $device);
    // Coming back cancels a pending deletion: the owner is still here.
    $pdo->prepare('UPDATE spaces SET deletion_requested_at = NULL, purge_at = NULL WHERE id = ?')
        ->execute([$space['id']]);

    send_json(200, ['space' => space_summary($space['id'])]);
}

function token_sharing(array $body): void
{
    $space = require_space();
    db()->prepare('UPDATE spaces SET shared = ? WHERE id = ?')
        ->execute([!empty($body['shared']) ? 1 : 0, $space['id']]);
    send_json(200, ['space' => space_summary($space['id'])]);
}

/** Drops one device from the space. The token still works elsewhere. */
function token_forget(array $body): void
{
    $space = require_space();
    db()->prepare('DELETE FROM devices WHERE space_id = ? AND device_id = ?')
        ->execute([$space['id'], (string)($body['deviceID'] ?? '')]);
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
                    $isLast = ($part === $parts - 1);
                    $append->execute([$payload, $isLast ? next_seq($spaceID) : 0,
                                      $spaceID, $entity, $id]);
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
                    $parts > 1 ? 0 : next_seq($spaceID),
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
    $purgeAt = now() + GRACE_DAYS * 86400;
    db()->prepare('UPDATE spaces SET deletion_requested_at = ?, purge_at = ? WHERE id = ?')
        ->execute([now(), $purgeAt, $space['id']]);
    send_json(200, ['ok' => true, 'purgeAt' => iso($purgeAt), 'graceDays' => GRACE_DAYS]);
}

function space_delete_cancel(): void
{
    $space = require_space();
    db()->prepare('UPDATE spaces SET deletion_requested_at = NULL, purge_at = NULL WHERE id = ?')
        ->execute([$space['id']]);
    send_json(200, ['ok' => true]);
}
