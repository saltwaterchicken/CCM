# Card Ingest: working notes

Keep this file current so any new session can pick up where the last one left off.
The full brief is `BRIEF.md`.

## Status

**Milestone 1: Detect, copy, verify, receipt.** In progress.

- [x] Step 1: Project skeleton, settings file with defaults, fake-card script, CI.
- [x] Step 2: Detect any removable card or drive and show it. Confirmed on the Mac with a real SD card.
- [x] Step 3: Copy, verify with xxHash64, write the receipt. Tests for copy and verify. Confirmed on the Mac.
- [ ] Step 4: Test on the photographer's Mac.

**Milestone 2: Folder and file naming.** Spec agreed 2026-10-23 (see "Naming" below). Not started.

- [ ] Step 1: Photographer initials and import counter in settings, shown and editable in the Job panel.
- [ ] Step 2: New folder name `YYYY-MM-DD-<initials><counter>` from today's date; counter goes up after each successful import.
- [ ] Step 3: Read each file's capture date and frame number; rename files on copy; tests.
- [ ] Step 4: Receipt shows original name next to new name. Confirm on the Mac with a real card.

## Decisions

- **Project layout:** a Swift package (`Package.swift`) with two parts. `CardIngestCore` holds
  all the logic and its tests. `CardIngest` is the thin SwiftUI app. Open `Package.swift` in
  Xcode to build and run. A full Xcode app project (for an icon, signing, menu bar) can wrap
  this later, around Milestone 6.
- **Settings:** one XML property list, defaults at
  `~/Library/Application Support/Card Ingest/Settings.plist`, created on first launch.
  The photographer can keep a separate settings file per project and load it in the app.
  Any key missing from a file falls back to its default, so project files can be short.
  The Settings screen (Milestone 6) will edit this same file. For now the main window has a
  Job panel (job name, destination, optional backup) that saves each change straight to the
  settings file in use, so editing while a project file is loaded changes that project file.
  The backup can't be the destination, inside it, or contain it; Copy refuses until that's fixed.
- **Look:** always dark, like Capture One, whatever the Mac's appearance setting: a near-black
  window with slightly lighter flat panels and small grey headings (`Theme` and `PanelStyle`
  in `CardIngestApp.swift`). Choose… panels and alerts are dark too.
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

- **Copying** (`CardCopier.swift`): files keep their folder layout from the card inside the
  destination folder for now (renaming is Milestone 2, see Naming). Each file is read from the card once,
  hashed while being written to every destination, then each copy is read back from the drive
  (bypassing the memory cache) and compared. Copies are written under a hidden `.partial` name
  and only get their real name once verified. The original's modified date is kept.
  The job stops at the first problem; unverified copies are removed, and no receipt is written.
  An existing identical file counts as already copied; a different file with the same name is
  never overwritten. Free space is checked before starting.
- **Receipt:** `Receipt_<card>_<yyyy-MM-dd_HHmmss>.csv` in each destination folder. One row per
  file (path, size, xxHash64, verified) followed by a short summary. Opens in Numbers or Excel.

## Naming (Milestone 2)

The photographer's spec, 2026-10-23. "ES" below stands for the photographer's initials, typed in
by hand (ES is just the example).

- **Card folder:** `{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}`, e.g. `2026-10-23-ES001`.
  The date is the day the card is imported. `iseq` is a 3-digit import counter that starts at 001
  and goes up by one for every card imported, across days and jobs, unless the photographer
  changes it. As a pattern: `{date:YYYY-MM-DD}-{artist}{iseq:3}`, made directly inside the
  destination root (no year folder, no job name; to be confirmed).
- **Files:** `{year4}-{month0}-{day0}-{artist}_{frame4}`, e.g. `2026-10-14-ES_1234.CR3`. Here the
  date is when the picture or clip was taken (EXIF DateTimeOriginal for photos, the creation date
  in the clip's metadata for video), not the import date. `frame4` is the last 4 digits of the
  number the camera put in its own file name (`IMG_1234.CR3` and `DSC01234.ARW` both give `1234`).
  The extension is kept, lowercase/uppercase as on the card. As a pattern:
  `{capture:YYYY-MM-DD}-{artist}_{frame:4}`.
- **Readings assumed until the photographer says otherwise:**
  - The spec writes `{artist}ES`; read as the initials appearing once (`{artist}` = the initials).
  - The counter is saved in the settings file and only goes up after a card copies and verifies.
  - RAW+JPEG pairs and sidecars (`.xmp`, `.thm`, `.wav`, `.lrv`) keep the same base name as the
    file they belong to, so `IMG_1234.CR3` + `IMG_1234.JPG` become `...-ES_1234.CR3` + `...-ES_1234.JPG`.
  - If two different files would get the same name (two cameras, or a camera's counter rolling
    over past 9999 in one day), the later one gets `-2`, `-3`, ... : `2026-10-14-ES_1234-2.CR3`.
    Nothing is ever overwritten.
  - No capture date in the file: use the file's modified date. No digits in the original name:
    use `0000` and let the duplicate rule number them.
  - Initials left empty: Copy refuses and asks for them.

## GUI wishlist

Suggestions so far, not yet decided. Edit freely.

- Remember the last few project settings files and offer them in a menu.
- Warn when the backup folder is on the same drive as the destination (it protects against a
  bad copy, not a dead drive).
- Show free space on each destination drive next to the folder, and how much the card needs.
- Drag a folder from Finder onto the Destination or Backup row to choose it.
- Show when a backup drive isn't plugged in, before Copy is pressed, instead of failing then.
- Show elapsed time and time remaining while copying.
- A menu bar icon showing a card is in and copying, so the window can stay closed.
- [x] A "Show Imported Files" button similar to the currently available "Show Receipt in Finder" so that the user doesn't need to navigate in the finder each time to find finished card.
- [x] The user interface should be dark or black like the software capture one pro or AI-Flow

## Open questions

- Because any removable drive now counts, a USB backup drive or thumb drive will be offered as a
  card too. Copying from it is harmless, but trashing (Milestone 5) needs a decision: confirm
  each one, or only auto-trash drives that look like camera cards.
- Should the app be called CCM instead of Card Ingest?

- Which cameras and file types are shot most? (Defaults cover Canon, Nikon, Sony, Fuji,
  Olympus/OM, Panasonic, Pentax, Leica DNG, plus common video.)
- Metadata template (needed for Milestone 2). Rename pattern is decided, see Naming.

## How to test what exists so far

1. Install Xcode from the Mac App Store and open it once.
2. In Terminal: `cd` into the project, then `swift test` (runs the tests) and
   `swift run -c release CardIngest` (opens the app; `-c release` makes copying and checksums
   much faster). Or open `Package.swift` in Xcode and press Run.
3. The app shows "Waiting for a card…", a Job panel, and the settings file path. Type a job
   name: "Copies go to" updates as you type. Press Choose… next to Destination and Backup to
   pick folders; Remove clears the backup. Quit and reopen the app: the choices are kept.
   "Show in Finder" reveals `Settings.plist`, which now has the new values. Choose the same
   folder for Backup as Destination: a red warning appears and Copy refuses to start.
4. `scripts/make-fake-card.sh` makes and mounts a pretend card named FAKECARD. Within a moment
   the app shows FAKECARD with "9 camera files" (MISC/SETTINGS.DAT isn't a camera file). Eject it in Finder
   and the app goes back to "Waiting for a card…".
5. Plug in any USB stick or card: it should show up too. Open "Other drives left alone": your
   Mac's own drive should be listed with the reason it was skipped.
6. With FAKECARD mounted, press Copy. The bar fills, then it says "Copied and verified 9 files".
   "Show Imported Files" opens the destination folder in Finder with the copied files in it;
   "Show Receipt in Finder" opens the destination folder with the receipt selected. Press Copy
   again: it finishes quickly because the files are already there and identical.
