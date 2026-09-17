<?php
/**
 * One PDO connection, in exceptions mode.
 *
 * `ERRMODE_EXCEPTION` matters more than it looks: with the default, a failed
 * write returns false and execution carries on, so a sync reports success and
 * stores nothing.
 */
function db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }
    // Production keeps config.php beside index.php. Local development points
    // CLIP_CONFIG at a file outside this folder, because this folder is shipped
    // inside the app - and a credentials file that ships is a credentials leak.
    $path = getenv('CLIP_CONFIG');
    if (!$path || !is_readable($path)) {
        $path = __DIR__ . '/../config.php';
    }
    $config = require $path;

    $dsn = sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4',
                   $config['db_host'], $config['db_name']);
    try {
        $pdo = new PDO($dsn, $config['db_user'], $config['db_pass'], [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
    } catch (PDOException $e) {
        // Never echo the driver message: it carries the host, the database name
        // and sometimes the user.
        error_log('clip-sync: database connection failed: ' . $e->getMessage());
        fail(500, 'The sync service could not reach its database.');
    }

    // Truncation must be an error, not a shrug. Without this a payload longer
    // than its column is silently cut and the clip comes back corrupted.
    $pdo->exec("SET SESSION sql_mode = 'STRICT_ALL_TABLES'");
    return $pdo;
}
