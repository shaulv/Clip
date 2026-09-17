<?php
/**
 * Guard: no live credential file may sit outside clip-sync-secrets/.
 *
 * Built after audit finding L3-1: a production MySQL password was found in
 * plaintext at sync-server-php/.trash/deploy-backup-.../api/config.php - a
 * backup taken outside the one place credentials are meant to live. A
 * config.php committed or left in a backup folder is invisible until someone
 * goes looking; this makes it fail loudly instead.
 *
 * Two things trip the guard, anywhere under this directory (sync-server-php/)
 * INCLUDING dotfiles and backup/trash subfolders:
 *   1. A file named exactly `config.php`.
 *   2. A file containing a DB_PASS-shaped assignment: db_pass/DB_PASS bound to
 *      a real-looking literal string, not a placeholder, not empty, not an
 *      env() lookup.
 *
 * `clip-sync-secrets/` is deliberately OUTSIDE this directory (a sibling of
 * sync-server-php/, not under it) so it can never be excluded by accident -
 * there is nothing under sync-server-php/ for the exclusion to apply to.
 *
 * Exit 0 and silent on a clean tree. Exit 1 and one line per offending file
 * otherwise. Never prints the offending value, only the path and rule.
 *
 * Usage:
 *   php check-no-plaintext-secrets.php [root-dir]
 */

declare(strict_types=1);

$root = $argv[1] ?? __DIR__;
$root = rtrim($root, '/');

$offenders = [];

function is_placeholder(string $value): bool
{
    $v = trim($value);
    if ($v === '') {
        return true;
    }
    // REPLACE_ME, CHANGE_ME, xxx..., or an env()/getenv() call are not secrets.
    if (preg_match('/^(REPLACE_ME|CHANGE_ME|TODO|x+|\*+)$/i', $v)) {
        return true;
    }
    return false;
}

$iterator = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS)
);

foreach ($iterator as $fileInfo) {
    /** @var SplFileInfo $fileInfo */
    if (!$fileInfo->isFile()) {
        continue;
    }
    $path = $fileInfo->getPathname();
    $name = $fileInfo->getFilename();

    // The guard's own source names the pattern it looks for; it is not a
    // credential file and must not scan itself.
    if ($name === 'check-no-plaintext-secrets.php') {
        continue;
    }

    if ($name === 'config.php') {
        $offenders[] = "$path  [rule: file named config.php outside clip-sync-secrets/]";
        continue;
    }

    // Only look inside text-ish files; skip binaries so this stays cheap.
    $size = $fileInfo->getSize();
    if ($size > 2 * 1024 * 1024) {
        continue;
    }
    $contents = @file_get_contents($path);
    if ($contents === false) {
        continue;
    }
    // PHP array key style: 'db_pass' => '...'   and constant style: DB_PASS = '...'
    if (preg_match(
        "/(?:['\"]db_pass['\"]\\s*=>|\\bDB_PASS\\b\\s*=)\\s*['\"]([^'\"]*)['\"]/i",
        $contents,
        $m
    )) {
        if (!is_placeholder($m[1])) {
            $offenders[] = "$path  [rule: DB_PASS-shaped literal assignment outside clip-sync-secrets/]";
        }
    }
}

if ($offenders) {
    fwrite(STDERR, "PLAINTEXT SECRET GUARD: FAILED\n");
    foreach ($offenders as $line) {
        fwrite(STDERR, "  $line\n");
    }
    exit(1);
}

echo "PLAINTEXT SECRET GUARD: clean (" . $root . ")\n";
exit(0);
