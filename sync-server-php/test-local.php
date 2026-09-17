<?php
/**
 * Exercises the whole sync API over real HTTP.
 *
 * The point of the size checks is that they would have failed before the work:
 * a payload over 64 KB against a `TEXT` column, and a batch past any single
 * request budget. A test that only pushes small rows proves nothing about the
 * thing the user actually asked for.
 *
 * Usage: php test-local.php [base-url]
 */

declare(strict_types=1);

$base = $argv[1] ?? 'http://127.0.0.1:8788';
$pass = 0;
$fail = [];

function check(string $name, bool $ok, $detail = ''): bool
{
    global $pass, $fail;
    if ($ok) {
        $pass++;
        echo "  [PASS] $name\n";
    } else {
        $fail[] = $name;
        echo "  [FAIL] $name" . ($detail !== '' ? "  -> " . substr((string)$detail, 0, 200) : '') . "\n";
    }
    return $ok;
}

function call(string $method, string $path, ?array $body = null, ?string $token = null): array
{
    global $base;
    $ch = curl_init($base . $path);
    $headers = ['Content-Type: application/json'];
    if ($token !== null) {
        $headers[] = 'Authorization: Bearer ' . $token;
    }
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_TIMEOUT        => 120,
        CURLOPT_POSTFIELDS     => $body === null ? null : json_encode($body),
    ]);
    $raw    = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $error  = curl_error($ch);
    if ($raw === false) {
        return ['status' => 0, 'body' => [], 'raw' => $error];
    }
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        $decoded = [];
    }
    // Always present, so a failing call reports its error rather than a PHP notice.
    $decoded += ['changes' => [], 'space' => [], 'cursor' => '0'];
    return ['status' => $status, 'body' => $decoded, 'raw' => $raw];
}

echo "\nTESTING $base\n";

// ------------------------------------------------------------------ health
echo "\n1. THE SERVICE ANSWERS\n";
$r = call('GET', '/health');
check('health responds', $r['status'] === 200, $r['raw']);
check('it identifies itself', ($r['body']['service'] ?? '') === 'clip-sync', $r['raw']);

// ------------------------------------------------------------------ tokens
echo "\n2. A TOKEN IS CREATED\n";
$r = call('POST', '/token/create', ['device' => 'Mac A', 'deviceID' => 'device-a']);
check('a token is issued', $r['status'] === 200, $r['raw']);
$token = $r['body']['token'] ?? '';
$parts = explode('-', $token);
check('it has the documented shape',
      count($parts) === 6 && $parts[0] === 'CLIP'
      && count(array_filter($parts, fn($p) => strlen($p) === 5)) === 5, $token);
check('it avoids the ambiguous letters',
      preg_match('/[ILOU]/', substr($token, 5)) === 0, $token);
check('the space starts empty', ($r['body']['space']['items'] ?? -1) === 0, $r['raw']);
check('and knows about one Mac', ($r['body']['space']['devices'] ?? 0) === 1, $r['raw']);
check('and starts shared so a second Mac can join',
      ($r['body']['space']['shared'] ?? false) === true, $r['raw']);

echo "\n3. THE TOKEN IS THE ONLY WAY IN\n";
check('no token is refused', call('POST', '/sync', ['since' => 0])['status'] === 401);
check('a made-up token is refused',
      call('POST', '/sync', ['since' => 0], 'CLIP-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA')['status'] === 401);
check('a token pasted without dashes still works',
      call('POST', '/token/claim', ['deviceID' => 'device-a', 'device' => 'Mac A'],
           str_replace('-', '', $token))['status'] === 200);
check('a token pasted in lower case still works',
      call('POST', '/token/claim', ['deviceID' => 'device-a', 'device' => 'Mac A'],
           strtolower($token))['status'] === 200);

// ------------------------------------------------------------------- sync
echo "\n4. CHANGES MOVE BETWEEN TWO MACS\n";
$r = call('POST', '/sync', ['since' => 0, 'changes' => [
    ['entity' => 'item', 'id' => 'item-1', 'updated_at' => 1000.0, 'payload' => '{"text":"one"}'],
    ['entity' => 'item', 'id' => 'item-2', 'updated_at' => 1001.0, 'payload' => '{"text":"two"}'],
]], $token);
check('Mac A uploads two items', $r['status'] === 200, $r['raw']);
check('and reads them back', count($r['body']['changes'] ?? []) === 2, $r['raw']);
$cursor = $r['body']['cursor'] ?? '0';

$r = call('POST', '/token/claim', ['deviceID' => 'device-b', 'device' => 'Mac B'], $token);
check('Mac B joins the space', $r['status'] === 200, $r['raw']);
check('the space now has two Macs', ($r['body']['space']['devices'] ?? 0) === 2, $r['raw']);

$r = call('POST', '/sync', ['since' => 0], $token);
check('Mac B sees both items', count($r['body']['changes'] ?? []) === 2, $r['raw']);

$r = call('POST', '/sync', ['since' => $cursor], $token);
check('and nothing repeats on the next sync', count($r['body']['changes'] ?? []) === 0, $r['raw']);

echo "\n5. LAST WRITE WINS, OLDER WRITES DO NOT\n";
call('POST', '/sync', ['since' => 0, 'changes' => [
    ['entity' => 'item', 'id' => 'item-1', 'updated_at' => 900.0, 'payload' => '{"text":"stale"}'],
]], $token);
$r = call('POST', '/sync', ['since' => 0], $token);
$one = null;
foreach ($r['body']['changes'] as $row) {
    if ($row['id'] === 'item-1') { $one = $row; }
}
check('an older copy does not overwrite a newer one',
      ($one['payload'] ?? '') === '{"text":"one"}', $one['payload'] ?? 'missing');

// --------------------------------------------------------------- no limit
echo "\n6. THERE IS NO CEILING ON WHAT IS STORED\n";

// 2 MB: past TEXT's 64 KB, and past the live server's ~1 MB body limit, so it
// can only arrive in parts. This is the case that failed against the real host
// after passing locally, which is the whole reason the suite runs against both.
$big = str_repeat('A quick brown fox jumps over the lazy dog. ', 50000);
$bigLength = strlen($big);
$bigPayload = json_encode(['text' => $big]);

$budget = 512 * 1024;                       // the client's per-request budget
$pieces = str_split($bigPayload, $budget);
$ok = true;
foreach ($pieces as $index => $piece) {
    $r = call('POST', '/sync', ['since' => 0, 'changes' => [
        ['entity' => 'item', 'id' => 'item-big', 'updated_at' => 2000.0,
         'payload' => $piece, 'part' => $index, 'parts' => count($pieces)],
    ]], $token);
    if ($r['status'] !== 200) {
        $ok = false;
        check(sprintf('part %d of %d was accepted', $index + 1, count($pieces)), false, $r['raw']);
        break;
    }
}
check(sprintf('a %s KB item uploads in %d parts', number_format($bigLength / 1024), count($pieces)),
      $ok && count($pieces) > 1, count($pieces));

$r = call('POST', '/sync', ['since' => 0], $token);
$back = null;
foreach ($r['body']['changes'] as $row) {
    if ($row['id'] === 'item-big') { $back = json_decode($row['payload'], true); }
}
check('it is reassembled byte for byte, not truncated',
      ($back['text'] ?? '') === $big,
      sprintf('sent %d, got %d', $bigLength, strlen($back['text'] ?? '')));

// A four-byte character at the boundary: utf8 (3 byte) columns drop these.
$emoji = str_repeat('🎉', 2000);
call('POST', '/sync', ['since' => 0, 'changes' => [
    ['entity' => 'item', 'id' => 'item-emoji', 'updated_at' => 2001.0,
     'payload' => json_encode(['text' => $emoji])],
]], $token);
$r = call('POST', '/sync', ['since' => 0], $token);
foreach ($r['body']['changes'] as $row) {
    if ($row['id'] === 'item-emoji') {
        $got = json_decode($row['payload'], true);
        check('four-byte characters survive', ($got['text'] ?? '') === $emoji,
              mb_strlen($got['text'] ?? ''));
    }
}

echo "\n7. A BIG HISTORY PAGES RATHER THAN FAILING\n";
$batch = [];
for ($i = 0; $i < 450; $i++) {
    $batch[] = ['entity' => 'item', 'id' => "bulk-$i", 'updated_at' => 3000.0 + $i,
                'payload' => json_encode(['text' => "bulk item $i"])];
}
$r = call('POST', '/sync', ['since' => 0, 'changes' => $batch], $token);
check('450 items upload in one batch', $r['status'] === 200, $r['raw']);
check('the response is one page, not everything',
      count($r['body']['changes']) === 200, count($r['body']['changes'] ?? []));
check('and it says there is more', ($r['body']['hasMore'] ?? false) === true, $r['raw']);

// Page through the lot the way the client does.
$seen = [];
$cursor = '0';
$pages = 0;
do {
    $r = call('POST', '/sync', ['since' => $cursor], $token);
    foreach ($r['body']['changes'] as $row) {
        $seen[$row['id']] = true;
    }
    $moved  = $r['body']['cursor'] !== $cursor;
    $cursor = $r['body']['cursor'];
    $pages++;
} while (($r['body']['hasMore'] ?? false) && $moved && $pages < 50);

check('paging reaches every item', count($seen) === 454, count($seen));
check('and it took more than one page', $pages > 1, $pages);
check('the last page says there is no more', ($r['body']['hasMore'] ?? true) === false, $r['raw']);

// ---------------------------------------------------------------- locking
echo "\n8. LOCKING THE TOKEN\n";
$r = call('POST', '/token/sharing', ['shared' => false], $token);
check('the space can be locked', ($r['body']['space']['shared'] ?? true) === false, $r['raw']);
$r = call('POST', '/token/claim', ['deviceID' => 'device-c', 'device' => 'Mac C'], $token);
check('a locked token refuses an unknown Mac', $r['status'] === 403, $r['raw']);
check('and says how to unlock it',
      strpos($r['body']['error'] ?? '', 'Unlock it in Clip') !== false, $r['raw']);
$r = call('POST', '/token/claim', ['deviceID' => 'device-b', 'device' => 'Mac B'], $token);
check('a Mac it already knows still syncs', $r['status'] === 200, $r['raw']);
call('POST', '/token/sharing', ['shared' => true], $token);

echo "\n9. FORGETTING A DEVICE\n";
$r = call('POST', '/token/forget', ['deviceID' => 'device-b'], $token);
check('a device can be dropped', ($r['body']['space']['devices'] ?? 0) === 1, $r['raw']);
check('and the token still works', call('POST', '/sync', ['since' => 0], $token)['status'] === 200);

echo "\n10. DELETION IS RECOVERABLE\n";
$r = call('POST', '/space/delete', [], $token);
check('deletion is accepted', $r['status'] === 200, $r['raw']);
check('it keeps a 30-day window', ($r['body']['graceDays'] ?? 0) === 30, $r['raw']);
$r = call('GET', '/space', null, $token);
check('the space still answers during the grace period', $r['status'] === 200, $r['raw']);
check('and reports the pending deletion',
      !empty($r['body']['space']['deletionRequestedAt']), $r['raw']);
$r = call('POST', '/space/delete/cancel', [], $token);
check('deletion can be cancelled', $r['status'] === 200, $r['raw']);
$r = call('GET', '/space', null, $token);
check('and the pending flag clears',
      empty($r['body']['space']['deletionRequestedAt']), $r['raw']);

echo "\n11b. /SYNC IS RATE LIMITED PER TOKEN (L3-3)\n";
// A fresh token/space so this section's traffic cannot be confused with the
// heavy paging test above sharing the same minute-window bucket.
$r = call('POST', '/token/create', ['deviceID' => 'throttle-test']);
$throttleToken = $r['body']['token'] ?? '';

// Allowed case: a handful of calls, far under the default cap
// (sync_per_minute in config.example.php), must all succeed.
$okCount = 0;
for ($i = 0; $i < 10; $i++) {
    $r = call('POST', '/sync', ['since' => 0, 'changes' => []], $throttleToken);
    if ($r['status'] === 200) {
        $okCount++;
    }
}
check('normal-rate sync traffic is never throttled', $okCount === 10, $okCount);

// Throttled case: hammer well past any sane per-minute cap and confirm the
// server actually pushes back, with a Retry-After a caller can act on.
$tripped = false;
$retryAfter = null;
for ($i = 0; $i < 80; $i++) {
    $ch = curl_init($base . '/sync');
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HEADER => true,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json',
                               'Authorization: Bearer ' . $throttleToken],
        CURLOPT_POSTFIELDS => json_encode(['since' => 0, 'changes' => []]),
    ]);
    $raw = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    if ($status === 429) {
        $tripped = true;
        if (preg_match('/Retry-After:\s*(\d+)/i', (string)$raw, $m)) {
            $retryAfter = (int)$m[1];
        }
        break;
    }
}
check('a runaway caller is throttled with 429', $tripped);
check('the 429 carries a Retry-After a caller can act on',
      $retryAfter !== null && $retryAfter > 0 && $retryAfter <= 60, $retryAfter);

echo "\n11. THE INTERNALS ARE NOT WEB RESOURCES\n";
foreach (['/config.php', '/lib/db.php', '/lib/store.php', '/config.example.php'] as $path) {
    $r = call('GET', $path);
    check("$path is not readable",
          $r['status'] >= 400 || strpos($r['raw'], 'db_pass') === false, $r['status']);
}

echo "\n" . str_repeat('=', 60) . "\n";
printf("%d passed, %d failed\n", $pass, count($fail));
foreach ($fail as $name) {
    echo "  FAILED: $name\n";
}
exit($fail ? 1 : 0);
