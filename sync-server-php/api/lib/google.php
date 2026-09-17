<?php
/**
 * Sign in with Google, mapped onto the space model that already exists.
 *
 * The design decision worth stating: **an account does not replace a token, it
 * issues one.** Everything downstream of `/auth/google` - claim, sync, sharing,
 * deletion - is untouched, because signing in ends with the client holding a
 * perfectly ordinary sync token that happens to have been minted for a Google
 * subject rather than typed by a person. That keeps one code path for the thing
 * that actually matters, and it means a user can sign out and still reach their
 * data by pasting the token.
 *
 * What is verified, and why each one matters:
 *   - The signature, against Google's published keys. Without it the endpoint
 *     accepts any JSON anybody cares to send and "identity" means nothing.
 *   - `iss`, so a token from some other issuer with a matching shape is refused.
 *   - `aud`, so an ID token minted for a *different* application - which is a
 *     token an attacker can obtain legitimately from their own app - cannot be
 *     replayed here. This is the check most implementations forget.
 *   - `exp`, with a small allowance for clock skew.
 *
 * The `sub` claim, not the email, is the identity. An email address can be
 * changed and re-assigned; `sub` is stable for the life of the account.
 */

declare(strict_types=1);

const GOOGLE_ISSUERS = ['https://accounts.google.com', 'accounts.google.com'];
const GOOGLE_JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
const GOOGLE_CLOCK_SKEW = 120;

/**
 * POST /auth/google - exchange a Google ID token for this account's sync token.
 *
 * Unauthenticated by necessity: the ID token *is* the credential. It is rate
 * limited for the same reason `/token/create` is.
 */
function auth_google(array $body, array $config): void
{
    $clientID = (string)($config['google_client_id'] ?? '');
    if ($clientID === '') {
        fail(503, 'This server is not set up for Google sign-in.');
    }
    throttle_or_fail('google', (int)($config['google_per_hour'] ?? 60));
    google_ensure_schema();

    // Two ways in, and the first is the one Clip uses.
    //
    // **The code exchange happens here, not in the app.** Google's Desktop
    // client type still requires `client_secret` at the token endpoint, PKCE or
    // no PKCE - which was the whole reason the first attempt failed with
    // "client_secret is missing". The choice was to ship the secret inside a
    // downloadable Mac app, or to hand the authorisation code to a server that
    // already holds it. The second is strictly better: the secret never leaves
    // this box, and the app gains nothing it could leak. PKCE still does its
    // job, because the verifier the app generated travels with the code and
    // Google checks it against the challenge it saw at the start.
    $code = (string)($body['code'] ?? '');
    if ($code !== '') {
        $idToken = google_exchange_code(
            $code,
            (string)($body['codeVerifier'] ?? ''),
            (string)($body['redirectUri'] ?? ''),
            $clientID,
            (string)($config['google_client_secret'] ?? '')
        );
    } else {
        $idToken = (string)($body['idToken'] ?? '');
    }
    if ($idToken === '') {
        fail(400, 'No Google identity was supplied.');
    }

    $claims = google_verify($idToken, $clientID);
    $subject = (string)($claims['sub'] ?? '');
    if ($subject === '') {
        fail(400, 'That Google identity carried no account id.');
    }
    // Google says whether it has actually confirmed the address. An unverified
    // one must not key an account: it is a claim, not a fact.
    if (isset($claims['email_verified']) && !$claims['email_verified']) {
        fail(403, 'That Google account has no verified email address.');
    }

    $pdo = db();
    $deviceID = (string)($body['deviceID'] ?? '');
    $device   = (string)($body['device'] ?? 'Mac');
    // Never invent one. An id made up here is written into `devices` and then
    // never sent again by anybody, so it stays for ever as a Mac the owner
    // cannot recognise and cannot get rid of - which is exactly what "I have
    // one Mac and it says two" turned out to mean.
    if ($deviceID === '') {
        fail(400, 'The request did not identify this device.');
    }

    // Existing account: hand back the token it already has.
    $find = $pdo->prepare('SELECT space_id, token FROM google_accounts WHERE subject = ?');
    $find->execute([$subject]);
    if ($row = $find->fetch()) {
        touch_device((string)$row['space_id'], $deviceID, $device);
        $pdo->prepare('UPDATE spaces SET deletion_requested_at = NULL, purge_at = NULL WHERE id = ?')
            ->execute([(string)$row['space_id']]);
        $pdo->prepare('UPDATE google_accounts SET last_seen = ? WHERE subject = ?')
            ->execute([now(), $subject]);
        send_json(200, [
            'token' => (string)$row['token'],
            'email' => (string)($claims['email'] ?? ''),
            'name'  => (string)($claims['name'] ?? ''),
            'picture' => (string)($claims['picture'] ?? ''),
            'space' => space_summary((string)$row['space_id']),
        ]);
    }

    // First sign-in: a new space, and a token minted for it.
    //
    // The token is stored in full here, unlike a pasted one. That is a real
    // trade and it is made deliberately: an account whose whole promise is
    // "sign in anywhere and your data is there" has to be able to hand the
    // token back, and it cannot do that from a hash. The mitigation is that
    // reaching it requires a valid, signed, audience-matched Google identity
    // for that exact subject.
    $token   = make_token();
    $spaceID = 'space-' . bin2hex(random_bytes(8));

    $pdo->beginTransaction();
    try {
        $pdo->prepare('INSERT INTO spaces (id, created_at, shared) VALUES (?,?,1)')
            ->execute([$spaceID, now()]);
        $pdo->prepare('INSERT INTO tokens (token_hash, space_id, created_at) VALUES (?,?,?)')
            ->execute([hash_token($token), $spaceID, now()]);
        $pdo->prepare(
            'INSERT INTO google_accounts (subject, email, space_id, token, created_at, last_seen)
             VALUES (?,?,?,?,?,?)'
        )->execute([$subject, (string)($claims['email'] ?? ''), $spaceID, $token, now(), now()]);
        touch_device($spaceID, $deviceID, $device);
        $pdo->commit();
    } catch (Throwable $e) {
        $pdo->rollBack();
        error_log('clip-sync: google sign-in failed: ' . $e->getMessage());
        fail(500, 'Could not set up your account.');
    }

    send_json(200, [
        'token' => $token,
        'email' => (string)($claims['email'] ?? ''),
        'name'  => (string)($claims['name'] ?? ''),
        'picture' => (string)($claims['picture'] ?? ''),
        'space' => space_summary($spaceID),
    ]);
}

/**
 * Creates the accounts table if it is not there yet.
 *
 * Shared hosting has no migration runner and no remote MySQL, so the choice was
 * a manual step in phpMyAdmin that somebody has to remember on every new
 * deployment, or an idempotent CREATE at the one place that needs the table.
 * The second is self-healing: a fresh install signs in and works, and an
 * existing one does nothing at all.
 *
 * The cost is one cheap statement per sign-in, which is a rounding error next
 * to the HTTPS round trip to Google that precedes it.
 */
function google_ensure_schema(): void
{
    db()->exec(
        'CREATE TABLE IF NOT EXISTS google_accounts (
            subject    VARCHAR(64)  NOT NULL,
            email      VARCHAR(320) NULL,
            space_id   VARCHAR(64)  NOT NULL,
            token      VARCHAR(64)  NOT NULL,
            created_at DOUBLE       NOT NULL,
            last_seen  DOUBLE       NOT NULL,
            PRIMARY KEY (subject),
            KEY google_space (space_id),
            CONSTRAINT google_space_fk FOREIGN KEY (space_id)
                REFERENCES spaces(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'
    );
}

/**
 * Trades an authorisation code for an ID token, using the secret held here.
 *
 * Returns only the ID token. The access and refresh tokens Google also sends
 * back are deliberately dropped on the floor: Clip asked for no scope that
 * grants access to anything, so an access token for it opens nothing, and
 * keeping one would be storing a credential with no purpose.
 */
function google_exchange_code(string $code, string $verifier, string $redirect,
                              string $clientID, string $clientSecret): string
{
    if ($verifier === '' || $redirect === '') {
        fail(400, 'That sign-in was incomplete.');
    }
    if ($clientSecret === '') {
        fail(503, 'This server has no Google client secret configured.');
    }

    $post = http_build_query([
        'client_id'     => $clientID,
        'client_secret' => $clientSecret,
        'code'          => $code,
        'code_verifier' => $verifier,
        'redirect_uri'  => $redirect,
        'grant_type'    => 'authorization_code',
    ]);

    $raw = @file_get_contents('https://oauth2.googleapis.com/token', false,
        stream_context_create([
            'http' => [
                'method'        => 'POST',
                'header'        => "Content-Type: application/x-www-form-urlencoded\r\n",
                'content'       => $post,
                'timeout'       => 20,
                // Google answers 400 with a body that says which parameter it
                // did not like. Without this the body is discarded and every
                // failure reads the same.
                'ignore_errors' => true,
            ],
            'ssl' => ['verify_peer' => true, 'verify_peer_name' => true],
        ]));

    if ($raw === false) {
        fail(503, 'Could not reach Google to complete the sign-in.');
    }
    $json = json_decode($raw, true);
    if (!is_array($json) || !isset($json['id_token'])) {
        $detail = is_array($json)
            ? (string)($json['error_description'] ?? $json['error'] ?? 'no id_token')
            : 'unreadable reply';
        fail(401, 'Google refused to complete the sign-in: ' . $detail);
    }
    return (string)$json['id_token'];
}

/** Verifies an ID token and returns its claims, or fails the request. */
function google_verify(string $jwt, string $clientID): array
{
    $parts = explode('.', $jwt);
    if (count($parts) !== 3) {
        fail(400, 'That is not a Google identity token.');
    }
    [$headerB64, $payloadB64, $signatureB64] = $parts;

    $header  = json_decode(base64url_decode($headerB64), true);
    $claims  = json_decode(base64url_decode($payloadB64), true);
    if (!is_array($header) || !is_array($claims)) {
        fail(400, 'That Google identity token could not be read.');
    }
    if (($header['alg'] ?? '') !== 'RS256') {
        // Refusing anything else is what closes the `alg: none` family of
        // attacks, where the caller picks the algorithm the server will trust.
        fail(400, 'Unsupported signature algorithm.');
    }

    $key = google_key((string)($header['kid'] ?? ''));
    $ok = openssl_verify(
        $headerB64 . '.' . $payloadB64,
        base64url_decode($signatureB64),
        $key,
        OPENSSL_ALGO_SHA256
    );
    if ($ok !== 1) {
        fail(401, 'That Google identity could not be verified.');
    }

    if (!in_array((string)($claims['iss'] ?? ''), GOOGLE_ISSUERS, true)) {
        fail(401, 'That identity was not issued by Google.');
    }
    if ((string)($claims['aud'] ?? '') !== $clientID) {
        fail(401, 'That identity was issued for a different application.');
    }
    if ((float)($claims['exp'] ?? 0) + GOOGLE_CLOCK_SKEW < now()) {
        fail(401, 'That sign-in has expired. Try again.');
    }
    return $claims;
}

/**
 * Google's public key for a key id, as a PEM.
 *
 * Cached on disk for an hour. Google rotates these, so caching for ever breaks
 * sign-in some days later with no deployment to blame; not caching at all makes
 * every sign-in wait on a second HTTPS round trip and hands Google a request per
 * login. An unknown `kid` bypasses the cache once, which is what makes a
 * rotation self-healing rather than an outage.
 */
function google_key(string $kid)
{
    if ($kid === '') {
        fail(400, 'That Google identity token names no signing key.');
    }
    $cacheFile = sys_get_temp_dir() . '/clip-google-jwks.json';
    $jwks = null;

    if (is_readable($cacheFile) && (time() - (int)filemtime($cacheFile)) < 3600) {
        $jwks = json_decode((string)file_get_contents($cacheFile), true);
        if (!google_jwks_has($jwks, $kid)) {
            $jwks = null;   // rotated: go and look again
        }
    }
    if ($jwks === null) {
        $raw = @file_get_contents(GOOGLE_JWKS_URL, false, stream_context_create([
            'http' => ['timeout' => 10],
            'ssl'  => ['verify_peer' => true, 'verify_peer_name' => true],
        ]));
        if ($raw === false) {
            fail(503, 'Could not reach Google to check that sign-in.');
        }
        $jwks = json_decode($raw, true);
        @file_put_contents($cacheFile, $raw);
    }
    if (!google_jwks_has($jwks, $kid)) {
        fail(401, 'That sign-in was signed with a key Google does not publish.');
    }
    foreach ($jwks['keys'] as $entry) {
        if (($entry['kid'] ?? '') === $kid) {
            return google_pem($entry);
        }
    }
    fail(401, 'That sign-in could not be checked.');
}

function google_jwks_has($jwks, string $kid): bool
{
    if (!is_array($jwks) || !is_array($jwks['keys'] ?? null)) {
        return false;
    }
    foreach ($jwks['keys'] as $entry) {
        if (($entry['kid'] ?? '') === $kid) {
            return true;
        }
    }
    return false;
}

/**
 * An RSA JWK as a PEM public key.
 *
 * Written out rather than pulled from a library: shared hosting has no composer
 * and no phpseclib, and this is fifteen lines of DER assembly against a format
 * that has not changed in twenty years.
 */
function google_pem(array $jwk)
{
    $modulus  = base64url_decode((string)($jwk['n'] ?? ''));
    $exponent = base64url_decode((string)($jwk['e'] ?? ''));
    if ($modulus === '' || $exponent === '') {
        fail(401, 'That signing key could not be read.');
    }

    $der = der_sequence(
        der_unsigned_integer($modulus) . der_unsigned_integer($exponent)
    );
    // SubjectPublicKeyInfo: the rsaEncryption OID, then the key as a BIT STRING.
    $algorithm = der_sequence(
        der_tlv(0x06, "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01") . der_tlv(0x05, '')
    );
    $spki = der_sequence($algorithm . der_tlv(0x03, "\x00" . $der));

    $pem = "-----BEGIN PUBLIC KEY-----\n"
         . chunk_split(base64_encode($spki), 64, "\n")
         . "-----END PUBLIC KEY-----\n";

    $key = openssl_pkey_get_public($pem);
    if ($key === false) {
        fail(500, 'This server could not read Google\'s signing key.');
    }
    return $key;
}

function der_tlv(int $tag, string $value): string
{
    $length = strlen($value);
    if ($length < 0x80) {
        $header = chr($length);
    } else {
        $bytes = ltrim(pack('N', $length), "\x00");
        $header = chr(0x80 | strlen($bytes)) . $bytes;
    }
    return chr($tag) . $header . $value;
}

function der_sequence(string $value): string
{
    return der_tlv(0x30, $value);
}

/** DER integers are signed, so a leading high bit needs a zero byte. */
function der_unsigned_integer(string $bytes): string
{
    $bytes = ltrim($bytes, "\x00");
    if ($bytes === '' ) {
        $bytes = "\x00";
    } elseif (ord($bytes[0]) > 0x7f) {
        $bytes = "\x00" . $bytes;
    }
    return der_tlv(0x02, $bytes);
}

function base64url_decode(string $value): string
{
    $padded = strtr($value, '-_', '+/');
    $remainder = strlen($padded) % 4;
    if ($remainder) {
        $padded .= str_repeat('=', 4 - $remainder);
    }
    $decoded = base64_decode($padded, true);
    return $decoded === false ? '' : $decoded;
}

/**
 * Forgets the mapping between a Google account and its space.
 *
 * The space and its data stay: signing out is not deleting, exactly as
 * disconnecting a token is not deleting. The user keeps their token and can
 * paste it back, and signing in again with the same account re-links.
 */
/**
 * The Google `sub` behind a fresh proof in this request, verified here.
 *
 * Takes the same two shapes `auth_google` does - an authorisation code to
 * redeem, or an id token already in hand - because the app's sign-in flow
 * produces a code and nothing else, and a caller that had to sign in twice to
 * remove one Mac would simply not do it.
 */
function google_subject_from_proof(array $body, array $config): string
{
    $clientID = (string)($config['google_client_id'] ?? '');
    if ($clientID === '') {
        fail(503, 'This server is not set up for Google sign-in.');
    }
    $code = (string)($body['code'] ?? '');
    if ($code !== '') {
        $idToken = google_exchange_code(
            $code,
            (string)($body['codeVerifier'] ?? ''),
            (string)($body['redirectUri'] ?? ''),
            $clientID,
            (string)($config['google_client_secret'] ?? '')
        );
    } else {
        $idToken = (string)($body['idToken'] ?? '');
    }
    if ($idToken === '') {
        fail(403, 'That action needs a fresh Google sign-in.');
    }
    $claims = google_verify($idToken, $clientID);
    return (string)($claims['sub'] ?? '');
}

function auth_google_forget(array $body): void
{
    $space = require_space();
    throttle_token_or_fail($space['id'], 'google_forget', 10);
    db()->prepare('DELETE FROM google_accounts WHERE space_id = ?')->execute([$space['id']]);
    db()->prepare('DELETE FROM devices WHERE space_id = ? AND device_id = ?')
        ->execute([$space['id'], (string)($body['deviceID'] ?? '')]);
    send_json(200, ['ok' => true]);
}
