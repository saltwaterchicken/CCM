# Card Ingest

A small, offline macOS app that copies a camera card to your photo folders, verifies every
copy, renames, adds metadata and a first-pass star rating, then clears and ejects the card.

Requires macOS 14 or later and Xcode 16 or later to build.

```sh
swift test             # run the tests
swift run CardIngest   # open the app
scripts/make-fake-card.sh   # mount a pretend card for testing
```

See `NOTES.md` for current status, decisions and testing steps.
