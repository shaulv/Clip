<?php
/**
 * Standalone cron entry point: sweeps expired spaces unconditionally.
 *
 * `/sync` already runs this sweep on a throttle (see maybe_purge_expired() in
 * lib/store.php), so a space is never left indefinitely just because nobody
 * happens to call /token/create. This script exists for the case that matters
 * more: a server with no traffic at all should still clean itself up, and a
 * cron-triggered run gives an operator something to point logs and alerting
 * at, separate from request traffic.
 *
 * Not reachable over HTTP by mistake: it is meant to be invoked by `php
 * purge.php` from cron or a shell, not through the router in index.php. If a
 * web server ever does serve it directly, running the sweep again does no
 * harm - it is idempotent - but PHP_SAPI is checked below so it refuses to be
 * useful as an accidental public endpoint.
 *
 * Usage (see README.md for the exact cron line):
 *   php /path/to/sync-server-php/api/purge.php
 */

declare(strict_types=1);

require __DIR__ . '/lib/http.php';
require __DIR__ . '/lib/db.php';
require __DIR__ . '/lib/store.php';

if (PHP_SAPI !== 'cli') {
    http_response_code(403);
    header('Content-Type: text/plain');
    echo "purge.php is a CLI/cron script, not a web endpoint.\n";
    exit(1);
}

$configPath = getenv('CLIP_CONFIG');
if (!$configPath || !is_readable($configPath)) {
    $configPath = __DIR__ . '/config.php';
}
// db() reads CLIP_CONFIG / config.php itself; this require is only to fail
// fast with a clear message if the config is missing before touching the DB.
if (!is_readable($configPath)) {
    fwrite(STDERR, "purge.php: no readable config at $configPath\n");
    exit(1);
}

$removed = purge_expired();
$now = gmdate('c');
echo "[$now] purge.php: removed $removed expired space(s).\n";
exit(0);
