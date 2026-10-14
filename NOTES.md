# Card Ingest: working notes

Keep this file current so any new session can pick up where the last one left off.
The full brief is `BRIEF.md`.

## Status

**Milestone 1: Detect, copy, verify, receipt.** In progress.

- [x] Step 1: Project skeleton, settings file with defaults, fake-card script, CI.
- [ ] Step 2: Detect a card (removable or ejectable, with a `DCIM` folder) and show it.
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

## Open questions

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
4. `scripts/make-fake-card.sh` makes and mounts a pretend card named FAKECARD. Eject it in Finder.
