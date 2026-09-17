# Google sign-in, in your own build

This repository does not carry the upstream project's sign-in service. The
address is stripped by `export-oss.sh`, because a published fork shipping it
would sync strangers into somebody else's database. So in this build, "Sign in
with Google" reports itself as unavailable, and the other two sync methods work
normally.

If you want it for your own build, here is the whole of what it takes.

## 1. A Google Cloud project

- Create a project, then an **OAuth consent screen** (External is fine).
- Request **only** `openid`, `email` and `profile`. Nothing else. Anything more
  is a sensitive scope, needs review, and Clip has no use for it.
- Create two credentials:
  - a **Desktop** client, whose id goes in the app;
  - a **Web** client, whose id *and secret* go on your server.

## 2. Put the client id in the app

In `Clip/Core/GoogleAuth.swift`:

```swift
static let clientID = "your-desktop-client-id.apps.googleusercontent.com"
```

This is not a secret. Google's own documentation says a desktop client id ships
inside the application. The client *secret* must never be in the app, and is
not.

## 3. Point the app at your service

In `Clip/Core/OfficialService.swift`, return your address:

```swift
static var url: URL? { URL(string: "https://your-host/api") }
```

The upstream build stores this XOR-ed so it does not appear in `strings`. That
is worth doing and worth being clear-eyed about: **an address inside a
downloadable app cannot be secret**, because the app must know where to connect
and a proxy watching one request recovers it. The address was never the security
boundary. Every endpoint requires a valid token or a verified identity token.
Knowing where the door is does not open it.

## 4. Configure the server

In your `config.php`:

```php
'google_client_id'     => 'your-web-client-id.apps.googleusercontent.com',
'google_client_secret' => 'your-web-client-secret',
```

## Why the server does the exchange

Google still requires `client_secret` at the token endpoint for this client
type, PKCE or not - the first attempt failed with exactly that error. The choice
was to ship the secret inside a downloadable app, or to move the exchange to the
server. The app sends the authorization code and its PKCE verifier; the server
holds the secret and does the exchange.

## What the server verifies

Not just that the token parses. All of it:

- the **signature**, against Google's live JWKS, with key rotation handled and a
  one-hour cache;
- the **audience** - the check most implementations skip, and the one that lets
  a token minted for a different application be replayed against yours;
- the **issuer** and the **expiry**;
- `alg: none` is refused outright;
- the account is keyed on the **subject**, never the email, and an unverified
  email cannot key an account.

There are tests for every one of those, including the ones that must be refused.
