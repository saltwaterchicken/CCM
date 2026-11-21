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

## Hidden game: Azimov's Rebellion

Turn-based artillery for one or two players, for while the cards copy. Choose **Window › Azimov's Rebellion**
(⇧⌘G). It opens full screen in its own classic Mac desktop; Help › Controls… in its menu bar lists the keys.

- **Card Progress:** a small green screen shows the card being copied (file, stage, speed, time left). It opens
  when a copy starts; its close box hides it, and File › Status Window brings it back.
- **Send Earth a Postcard:** after a round, saves a 3000 × 1688 picture of the planet in the current card folder.
  It goes up to the Server with that card on the next Sync With Server.
- **Leaving:** the close box (top left), File › Close or ⌘W. The zoom box (top right) leaves or enters full screen.

The game is one page, `Resources/azimovs-rebellion.html`, copied unchanged from the photographer's own build.
It uses no network and also opens in a browser on its own.
