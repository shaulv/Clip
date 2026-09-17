# Clip sync service (PHP + MySQL)

The sync service. Deploy it to any PHP 8 host with MySQL; see `docs/SELF-HOSTING.md`.

It speaks the same HTTP API as the local Python service in `../sync-server/`, so
the app switches between them by changing one base URL. The Python one stays for
offline development; this one is what the app talks to by default.

## Why a rewrite rather than an upload

GoDaddy shared hosting runs PHP and MySQL and will never run a long-lived Python
process. The contract is what matters, not the implementation.

## Storage limits

There are none, and each place one appears by accident is dealt with explicitly:

| Where a limit hides | What was done |
|---|---|
| Column type | `payload` is `LONGTEXT` (4 GiB). `TEXT` is 64 KB, and MySQL truncates silently in its default mode - a corrupted clip that reports success. |
| Request size | Set by the host and unraisable from here. The **client** chunks its upload by byte budget and pages the download, so any history syncs through any limit. |
| Row count | No cap, and nothing is purged. |
| Per-space quota | None. The only ceiling is the hosting account's disk. |

`SET SESSION sql_mode = 'STRICT_ALL_TABLES'` makes truncation an error rather
than a warning, so the silent case cannot come back.

## Layout

```
api/index.php      router and endpoints
api/purge.php      cron entry point: sweeps expired spaces (see below)
api/lib/http.php   request, response, and the bearer token
api/lib/db.php     one PDO connection
api/lib/store.php  spaces, tokens, devices, records, throttling
api/config.php     credentials - gitignored, uploaded by hand
schema.sql         imported once through phpMyAdmin
```

## Expired-space cleanup

`purge_expired()` in `api/lib/store.php` deletes any space past its 30-day
deletion grace period. It runs two ways:

- Automatically, throttled to once an hour, from `/sync` (the endpoint that is
  actually called on a schedule by every client) - so a deleted space does not
  sit indefinitely just because nobody happens to call `/token/create`.
- On demand, unconditionally, via `api/purge.php` - a plain CLI script, not a
  web endpoint (`.htaccess` denies it, and it also refuses itself when
  `PHP_SAPI` is not `cli`). Point a cron job at it so cleanup still happens on
  a server with no sync traffic at all:

```
0 4 * * * /usr/bin/php /home/USER/public_html/clipassets/api/purge.php >> /home/USER/logs/clip-purge.log 2>&1
```

Adjust the PHP binary path and the `public_html` path to the actual cPanel
account; both are visible from the cPanel "Cron Jobs" page.

## Rate limits

- `/token/create`: `tokens_per_hour` per IP (unauthenticated, so IP is the only
  identity available).
- `/sync`: `sync_per_minute` per space/token (authenticated, so the token - not
  the IP - is the identity that matters). Tripping it returns `429` with a
  `Retry-After` header naming the number of seconds until the current window
  ends. The default (60/minute) sits far above a real client, which syncs on a
  60-second timer plus one immediate sync per local change.

## Credential hygiene guard

`check-no-plaintext-secrets.php` fails if a `config.php` or a `db_pass`/
`DB_PASS`-shaped literal assignment exists anywhere under this directory
outside `clip-sync-secrets/` (a sibling directory, never scanned). It runs in
two places: `deploy.sh`'s preflight (refuses to deploy) and
`Clip/security-probe.py` (fails the probe). Run it by hand with:

```
php check-no-plaintext-secrets.php .
```

## Deploying

database, import `schema.sql`, upload a zip of `api/` into
`public_html/clipassets/`, extract, verify `/health`.

## Local test

`php test-local.php` runs the whole lifecycle against a local MySQL, including a
payload larger than a `TEXT` column and larger than one request budget.
