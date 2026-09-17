# A stable local signing identity

## The problem this solves

Without a signing identity, every build of Clip is **ad-hoc signed**, which
means every build is a different identity as far as macOS is concerned. A
Keychain item is bound to the identity that created it, so each new build makes
the system ask again:

> Clip wants to use your confidential information stored in "app.clip.ai" in
> your keychain.

Clicking **Always Allow** grants it to *that* binary, and the next build is a
new binary. During development that is a password prompt every few minutes, and
it cannot be answered at all when Clip is running as a menu-bar agent with no
window - the call simply blocks for ever.

The real fix is one identity that does not change between builds.

## The proper answer

An Apple **Developer ID Application** certificate ($99/year). `package.sh`
prefers it automatically when it is present, and it is also the only route to
notarisation, which is what removes Gatekeeper's warning on first open.

## The free answer: a self-signed identity

This gives up notarisation but keeps the part that matters day to day: one
stable identity, so Keychain access is granted once and stays granted.

The certificate is generated locally. Nothing leaves the machine, and no key
is shared with anything.

```sh
# 1. Generate the certificate and key (writes three files to /tmp).
cat > /tmp/clip-cert.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Clip Local Signing
O = Clip
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
1.2.840.113635.100.6.1.13 = critical,DER:0500
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config /tmp/clip-cert.cnf \
  -keyout /tmp/clip-signing.key -out /tmp/clip-signing.crt

openssl pkcs12 -export -out /tmp/clip-signing.p12 \
  -inkey /tmp/clip-signing.key -in /tmp/clip-signing.crt \
  -passout pass: -name "Clip Local Signing"

# 2. Put it in the login keychain and let codesign use it.
#    macOS will ask for your login password once.
security import /tmp/clip-signing.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "" -T /usr/bin/codesign

# 3. Trust it for code signing. Asks for your password once more.
sudo security add-trusted-cert -d -r trustRoot \
  -p codeSign -k /Library/Keychains/System.keychain /tmp/clip-signing.crt

# 4. Check it is there.
security find-identity -v -p codesigning
```

The last command must list `Clip Local Signing`. After that, `./package.sh`
picks it up on its own - there is nothing to configure.

Then install once and grant Keychain access once. Every later build carries the
same signature, so nothing asks again.

## Removing it

```sh
sudo security delete-certificate -c "Clip Local Signing" /Library/Keychains/System.keychain
security delete-identity -c "Clip Local Signing"
```

## What this does NOT change

- Gatekeeper still warns on first open: right-click the app, choose **Open**.
  Only notarisation removes that.
- Automated test runs never needed any of this. A sandboxed run keeps its
  secrets in a file inside its own throwaway directory and never touches the
  Keychain at all - see `Core/TestIsolation.swift`.
