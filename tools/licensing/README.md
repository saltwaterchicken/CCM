# License keys

Media Sherpa unlocks with a license key that runs out after a set time. Keys are
checked on the photographer's Mac alone (no server, no internet): each is a small
payload (email, issued, expires) signed with an Ed25519 private key that only you
have. The app holds the matching public key (`License.publicKey` in
`Sources/MediaSherpaCore/License.swift`), which can check keys but never make them.

`license.swift` here is for your Mac only. It isn't part of the Swift package, so
it's never built into the app.

## Once: make the keypair

    swift tools/licensing/license.swift generate-keypair

This saves the private key to `~/.mediasherpa/license_private.key`, readable only by
you, and prints the public key. Put that in `License.publicKey` and rebuild the app.
(Already done on 2026-10-27; it refuses to replace an existing private key, as every
key issued with it would stop working.)

**Back the private key up somewhere safe and offline** (a USB stick in a drawer, or
your password manager). Without it you can't issue or renew keys, and a new keypair
means a new app build and new keys for everyone. Never commit it, email it or put
it in the app: `.gitignore` leaves out `*.key` and `license_private*` as a backstop.

## Issue a key

    swift tools/licensing/license.swift issue-license --email someone@example.com --months 6
    swift tools/licensing/license.swift issue-license --email someone@example.com --expires 2027-04-30

It prints one line starting `CI1-`. Email that line to the photographer. They paste
it in the License window (it opens by itself until a key is in, or Help ›
License…) and press Activate. Spaces and line breaks added by email apps are
ignored. The key works through the end of its expiry day.

## Renew

Issue a new key with a later expiry for the same email and send it. They paste it
after Help › License… › Enter New Key…. From 14 days before the end, the app shows
a reminder at the top of its window.

## What happens without a working key

Copying cards and Sync With Server are off, and the License window says why
(no key, not a valid key, ran out, or the Mac's clock set back more than 2 days
from a date the app has seen). A copy already running when a key runs out still
finishes and verifies. Photos already copied can still be opened and rated, and
nothing on any drive is changed or deleted.

## Limits

- A key can't be taken back before it ends: it's checked offline. The expiry is
  what limits a shared key, so keep keys short enough to be comfortable.
- One key per email works on any number of Macs.
- Anyone with the source code could build a copy without the check, so keep the
  repository private.
