# Media Sherpa

A small, offline macOS app that copies a camera card to your photo folders, verifies every
copy, renames, adds metadata and a first-pass star rating, then clears and ejects the card.

Requires macOS 14 or later and Xcode 16 or later to build.

```sh
swift test             # run the tests
swift run MediaSherpa   # open the app
scripts/make-fake-card.sh   # mount a pretend card for testing
scripts/make-app.sh    # build "CC Media Sherpa.app" into /Applications for double-click use
```

Or double-click `Make App.command` in Finder, which does the same. `Ship/Settings.plist` is the settings new users
start from; edit it in any text editor before building.

See `NOTES.md` for current status, decisions and testing steps.
