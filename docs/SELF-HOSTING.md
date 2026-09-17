# Running your own sync server

Clip's "your own server" method needs a PHP 8 host with MySQL. That is it - no
composer, no extensions beyond PDO, no build step. It runs on the cheapest
shared hosting there is.

Nothing in this document sends your data anywhere but your own host.

## The short route: let Clip write it for you

Clip generates the whole thing.

1. Open **Settings ▸ Sync**, choose **Set up a sync server**.
2. Fill in the address you will host it at, the database name, user and
   password.
3. Press **Create the setup kit**. Clip writes a folder containing the server
   code, a filled-in `config.php`, and `START-HERE.html` with the steps for
   your details.
4. Upload the `api` folder to your host, create the database and user, and open
   the address in a browser. It should report that it is healthy.
5. Back in Clip, press **Test**, then **Create a sync token**.

The token is the account. Paste it into Clip on another Mac to join them. There
is no sign-up, no email, and no password - which is the point.

## The manual route

```bash
cp sync-server-php/api/config.example.php sync-server-php/api/config.php
# edit config.php: database host, name, user, password
# upload sync-server-php/api/ to your host
curl https://your-host/path/to/api/health
```

The schema is created on first use. There is nothing to import.

## What it stores

One `records` table, scoped by space. Each row is an entity (`item` or
`settings`), an id, an `updated_at`, a deleted flag and a payload. Deletions are
tombstones, so a delete on one Mac reaches the others.

Only `sha256(token)` is stored. Someone with a database dump and no token
cannot sync with it.

## Security, briefly

The server takes the space id **from the token, never from the request body**,
so a caller naming someone else's space reaches nothing. Every statement is
parameterised. Bodies are capped at 8 MB. A space can be locked so no new device
may claim its token.

Serve it over HTTPS. A sync token in a request header over plain HTTP is
readable by anyone on the path, and the token is the whole of the authentication.

## Google sign-in

Self-hosting does not give you Google sign-in. That method is tied to a specific
deployment and OAuth client - see [GOOGLE-SIGN-IN.md](GOOGLE-SIGN-IN.md) if you
want to stand up your own. For most people the token is simpler and gives up
nothing.
