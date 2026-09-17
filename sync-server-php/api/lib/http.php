<?php
/**
 * Request and response plumbing.
 */

/**
 * The largest request the service will read.
 *
 * The app caps what it captures, but the server must not trust the app: any
 * client can post whatever it likes. Without a cap, one caller can fill the
 * database, exhaust the memory limit of a shared host and take the service
 * down for every other account on it.
 *
 * 8 MB is comfortably above a real sync - a page of records with a 512 KB
 * capture limit - and far below what hurts.
 */
const MAX_REQUEST_BYTES = 8 * 1024 * 1024;

/** The JSON body, or an empty array. */
function request_body(): array
{
    // Refuse on the declared length first, so an oversized body is rejected
    // before it is read into memory rather than after.
    $declared = (int)($_SERVER['CONTENT_LENGTH'] ?? 0);
    if ($declared > MAX_REQUEST_BYTES) {
        send_json(413, ['error' => 'That request is too large.']);
        exit;
    }
    $raw = file_get_contents('php://input', false, null, 0, MAX_REQUEST_BYTES + 1);
    if ($raw === false || $raw === '') {
        return [];
    }
    // A body with no Content-Length, or a lying one, is caught here.
    if (strlen($raw) > MAX_REQUEST_BYTES) {
        send_json(413, ['error' => 'That request is too large.']);
        exit;
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

/**
 * The bearer token.
 *
 * Apache with CGI or FastCGI drops the Authorization header before PHP is
 * reached, and the symptom is every authorised call returning 401 while the
 * token is provably right - a whole afternoon if you go looking in the wrong
 * layer. The .htaccess copies the header into an environment variable; this
 * reads every place it can end up, in order.
 */
function bearer_token(): string
{
    $candidates = [
        $_SERVER['HTTP_AUTHORIZATION'] ?? '',
        $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '',
    ];
    if (function_exists('apache_request_headers')) {
        foreach (apache_request_headers() as $name => $value) {
            if (strcasecmp($name, 'Authorization') === 0) {
                $candidates[] = $value;
            }
        }
    }
    foreach ($candidates as $candidate) {
        if (stripos($candidate, 'Bearer ') === 0) {
            return trim(substr($candidate, 7));
        }
    }
    return '';
}

function send_json(int $status, array $payload): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    // The API is called by a native app, not a browser, so no origin is allowed
    // to call it from a page. Saying so explicitly beats leaving it to a default.
    header('X-Content-Type-Options: nosniff');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function fail(int $status, string $message): void
{
    send_json($status, ['error' => $message]);
}

/**
 * A 429 that tells the caller when it is worth trying again, rather than a
 * bare refusal it has to guess about. `Retry-After` in seconds, per RFC 9110.
 */
function fail_too_many(string $message, int $retryAfterSeconds): void
{
    header('Retry-After: ' . max(1, $retryAfterSeconds));
    send_json(429, ['error' => $message]);
}

/** The caller's address, for throttling only. */
function client_ip(): string
{
    return (string)($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');
}

function now(): float
{
    return microtime(true);
}

function iso(float $timestamp): string
{
    return gmdate('c', (int)$timestamp);
}
