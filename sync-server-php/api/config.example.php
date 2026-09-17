<?php
/**
 * Copy to config.php and fill in the production values.
 *
 * config.php is gitignored and is uploaded by hand. It must never be committed,
 * pasted into a plan, or quoted in a message.
 */
return [
    // GoDaddy shared hosting: the application and MySQL are on the same box.
    'db_host' => 'localhost',
    'db_name' => 'clip_sync',
    'db_user' => 'REPLACE_ME',
    'db_pass' => 'REPLACE_ME',

    // A token is a bearer credential and is readable in transit over plain HTTP.
    'require_https' => true,

    // Rows returned per /sync response. Not a cap on what a space may hold: the
    // client pages until the cursor stops moving.
    'page_size' => 200,

    // A page is bounded by bytes as well as rows, so a page of large clips
    // cannot outgrow the memory limit.
    'page_bytes' => 4194304,

    // Creating a space is unauthenticated by design, so it is rate limited.
    'tokens_per_hour' => 20,

    // /sync is authenticated, but it still does real database work on shared
    // hosting. The client syncs on a 60-second timer plus one immediate sync
    // per local change, so a real session sits far under this; it exists for
    // a runaway retry loop, not for normal use.
    'sync_per_minute' => 60,

    // Sign in with Google.
    //
    // The client id is NOT a secret - it ships inside the Mac app, as Google
    // intends for a desktop client. It is here because the server has to check
    // that an incoming ID token was minted for *this* application: without the
    // `aud` check, an ID token obtained legitimately by any other Google app
    // could be replayed here as an identity. Leave it empty to turn Google
    // sign-in off; the endpoint then refuses with a plain 503.
    'google_client_id' => '',

    // Unauthenticated by necessity - the identity token is the credential - so
    // it is rate limited like token creation.
    // The client secret. Unlike the id, this IS a secret - which is precisely
    // why the authorisation-code exchange happens on the server rather than in
    // the Mac app. Google's Desktop client type demands it at the token
    // endpoint even when PKCE is used, and a secret shipped inside a
    // downloadable binary is not one.
    'google_client_secret' => '',

    'google_per_hour' => 60,
];
