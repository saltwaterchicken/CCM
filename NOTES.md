# Card Ingest: working notes

Keep this file current so any new session can pick up where the last one left off.
The full brief is `BRIEF.md`.

## Status

**Milestone 1: Detect, copy, verify, receipt.** In progress.

- [x] Step 1: Project skeleton, settings file with defaults, fake-card script, CI.
- [x] Step 2: Detect any removable card or drive and show it. Waiting on a test on the Mac.
- [ ] Step 3: Copy, verify with xxHash64, write the receipt. Tests for copy and verify.
- [ ] Step 4: Test on the photographer's Mac.

## Decisions

- **Project layout:** a Swift package (`Package.swift`) with two parts. `CardIngestCore` holds
  all the logic and its tests. `CardIngest` is the thin SwiftUI app. Open `Package.swift` in
  Xcode to build and run. A full Xcode app project (for an icon, signing, menu bar) can wrap
  this later, around Milestone 6.
- **Settings:** one XML property list, defaults at
  `~/Library/Application Support/Card Ingest/Settings.plist`, created on first launch.
  The photographer can keep a separate settings file per project and load it in the app.
  Any key missing from a file falls back to its default, so project files can be short.
  The Settings screen (Milestone 6) will edit this same file.
- **Default destination:** `~/Pictures/Card Ingest/{date:YYYY}/{date:YYYY-MM-DD}_{job}`,
  e.g. `~/Pictures/Card Ingest/2026/2026-10-14_Smith Wedding/`.
- **Default rename pattern:** `{date:YYYY-MM-DD}_{job}_{camera}_{seq:4}` (used from Milestone 2).
- **Pattern fields:** `{date:FORMAT}` (YYYY, YY, MM, DD, hh, mm, ss), `{job}`, `{camera}`,
  `{serial}`, `{original}`, `{seq:N}`. A `/` in the pattern makes a subfolder; `/` or `:`
  inside a value becomes `-`, and `..` is ignored, so nothing can escape the destination.
- **Second backup destination:** optional (empty `backupRoot` means none).
- **Checksum:** xxHash64, implemented in-house (no third-party package).
- **CI:** GitHub Actions on a macOS runner builds and runs the tests on every push, and fails
  if any `diskutil erase`/`partition`-style command appears in the code. The development
  machine is Linux and can't build macOS apps, so CI is how code gets checked before it
  reaches the photographer.

- **What counts as a card** (`CardRules` in `CardDetection.swift`, the only place this is decided):
  any removable or ejectable drive, with or without a `DCIM` folder (the photographer's call,
  2026-10-22: the brief's DCIM requirement was too specific). Still never the startup drive,
  a fixed internal drive, a network volume, or a drive holding the destination or backup folder.
  A Mac's built-in SD slot reports cards as internal but removable, so internal only rules a
  drive out when it isn't removable (found testing with a real card, 2026-10-22). Disk images
  count because they are ejectable, which is what makes the fake card work.
- **Scanning:** every file on the drive with a listed extension is counted, wherever it is
  (DCIM, Sony's PRIVATE/M4ROOT, etc.). Hidden files and folders (`._*`, `.DS_Store`,
  `.Trashes`) and other file types are skipped. A folder that can't be read stops
  the scan with an error instead of being quietly skipped.

## Open questions

- Because any removable drive now counts, a USB backup drive or thumb drive will be offered as a
  card too. Copying from it is harmless, but trashing (Milestone 5) needs a decision: confirm
  each one, or only auto-trash drives that look like camera cards.
- Should the app be called CCM instead of Card Ingest?

- Which cameras and file types are shot most? (Defaults cover Canon, Nikon, Sony, Fuji,
  Olympus/OM, Panasonic, Pentax, Leica DNG, plus common video.)
- Exact rename pattern and metadata template (needed for Milestone 2).

## How to test what exists so far

1. Install Xcode from the Mac App Store and open it once.
2. In Terminal: `cd` into the project, then `swift test` (runs the tests) and `swift run CardIngest`
   (opens the app). Or open `Package.swift` in Xcode and press Run.
3. The app shows "Waiting for a card…", the settings file path, and where copies will go.
   "Show in Finder" reveals `Settings.plist`; open it in TextEdit or Xcode, change `jobName`,
   save, press Reload, and the destination updates.
4. `scripts/make-fake-card.sh` makes and mounts a pretend card named FAKECARD. Within a moment
   the app shows FAKECARD with "9 camera files" (MISC/SETTINGS.DAT isn't a camera file). Eject it in Finder
   and the app goes back to "Waiting for a card…".
5. Plug in any USB stick or card: it should show up too. Open "Other drives left alone": your
   Mac's own drive should be listed with the reason it was skipped.
