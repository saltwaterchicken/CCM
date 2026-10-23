# Card Ingest: working notes

Keep this file current so any new session can pick up where the last one left off.
The full brief is `BRIEF.md`.

## Status

**Milestone 1: Detect, copy, verify, receipt.** In progress.

- [x] Step 1: Project skeleton, settings file with defaults, fake-card script, CI.
- [x] Step 2: Detect any removable card or drive and show it. Confirmed on the Mac with a real SD card.
- [x] Step 3: Copy, verify with xxHash64, write the receipt. Tests for copy and verify. Confirmed on the Mac.
- [ ] Step 4: Test on the photographer's Mac.

**Milestone 2: Folder and file naming.** Spec agreed 2026-10-23 (see "Naming" below). Done:
built, tested, and confirmed on the Mac with a real card (2026-10-22).

- [x] Step 1: Token patterns (`{todayyear4}`, `{iseq}`, `{frame4}`, ...) in NameTemplate, with tests.
- [x] Step 2: "Job name" becomes "Folder name" holding the pattern; import counter in settings and the
  Job panel; card folder `2026-10-23-ES001`; counter goes up after each successful import.
- [x] Step 3: Read each file's capture date and frame number; rename files on copy; tests.
- [x] Step 4: Receipt shows original name next to new name. Confirmed on the Mac with a real card.

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
  Job panel (folder name, next import number, destination, optional backup) that saves each
  change straight to the settings file in use, so editing while a project file is loaded
  changes that project file (including its import counter).
  Milestone 1 files still load: their `jobName` and `folderPattern` are ignored (dropped on the
  next save), and the old default rename pattern, which was never used, becomes the new one.
  The backup can't be the destination, inside it, or contain it; Copy refuses until that's fixed.
- **Look:** always dark, like Capture One, whatever the Mac's appearance setting: a near-black
  window with slightly lighter flat panels and small grey headings (`Theme` and `PanelStyle`
  in `CardIngestApp.swift`). Choose… panels and alerts are dark too.
- **Default destination:** `~/Pictures/Card Ingest`, with each card's folder directly inside,
  e.g. `~/Pictures/Card Ingest/2026-10-23-ES001/`. Patterns and tokens: see Naming.
  A pattern always makes one name: `/` or `:` becomes `-`, so nothing can escape the destination.
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

- **Copying** (`CardCopier.swift`): files go flat into the card folder under their new names
  (`ImportPlanner.swift` decides the folder and names first). Each file is read from the card once,
  hashed while being written to every destination, then each copy is read back from the drive
  (bypassing the memory cache) and compared. Copies are written under a hidden `.partial` name
  and only get their real name once verified. The original's modified date is kept.
  The job stops at the first problem; unverified copies are removed, and no receipt is written.
  An existing identical file counts as already copied; a different file with the same name is
  never overwritten. Free space is checked before starting.
- **Receipt:** `Receipt_<card>_<yyyy-MM-dd_HHmmss>.csv` in each destination folder. One row per
  file (new name, original path on the card, size, xxHash64, verified) followed by a short
  summary including the import number. Opens in Numbers or Excel.

## Naming (Milestone 2)

The photographer's spec, 2026-10-23. "ES" below is the photographer's initials, typed into the
pattern by hand like any other text (ES is just the example).

- **Tokens:** patterns use Photo Mechanic-style tokens in braces. Anything outside braces is
  copied as typed.
  - Import date (today): `{todayyear4}`, `{todayyear2}`, `{todaymonth0}`, `{todayday0}`
    (the 0 means zero-padded: `03`).
  - Capture date (when the picture or clip was taken): `{year4}`, `{year2}`, `{month0}`,
    `{day0}`, `{hour0}`, `{minute0}`, `{second0}`. Read from EXIF DateTimeOriginal for photos and
    RAW, the clip's creation date for video; the file's modified date if neither exists.
  - `{iseq}`: the import counter, 3 digits (`001`). Starts at 001, goes up by one for every card
    imported, across days and jobs, unless the photographer changes it. Saved in the settings
    file; only goes up after a card copies and verifies.
  - `{frame4}`: the last 4 digits of the number the camera put in its own file name
    (`IMG_1234.CR3` and `DSC01234.ARW` both give `1234`); `0000` if there are none.
  - `{filename}`: the camera's original file name without its extension.
  - An unknown token stops Copy with a message naming it, so typos are caught before copying.
- **Card folder:** the Job panel's "Job name" field becomes "Folder name" and holds the pattern
  itself. Default `{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}`, which makes
  `2026-10-23-ES001`, created directly inside the destination (no year folder). This replaces
  both `jobName` and `folderPattern`. The Job panel shows what the pattern turns into as you type.
- **Files:** default pattern `{year4}-{month0}-{day0}-ES_{frame4}`, e.g. `2026-10-14-ES_1234.CR3`.
  The extension is kept as on the card. Files go flat into the card folder (no DCIM subfolders).
  The spec wrote this as `{artist}ES`; the photographer confirmed the initials appear once, so
  the default just types ES.
- **Other rules (confirmed "mostly correct" by the photographer, 2026-10-23):**
  - RAW+JPEG pairs and sidecars (`.xmp`, `.thm`, `.wav`, `.lrv`) keep the same base name as the
    file they belong to: `IMG_1234.CR3` + `IMG_1234.JPG` become `...-ES_1234.CR3` + `...-ES_1234.JPG`.
  - If two different files would get the same name (two cameras, or a camera's counter rolling
    over past 9999 in one day), the later one gets `-2`, `-3`, ... : `2026-10-14-ES_1234-2.CR3`.
    Nothing is ever overwritten.
  - If the card folder already exists from a different card, the counter skips to the next free
    number instead of mixing cards.
- **How these were built** (decided while building, 2026-10-22; `ImportPlanner.swift`):
  - Tokens ignore case. `{frame4}` uses the last run of digits in the camera's name, so
    GoPro's `GX010007` gives `0007`; fewer than 4 digits are padded (`IMG_12` gives `0012`).
  - Capture-date tokens, `{frame4}` and `{filename}` only work in file names; in the folder name
    they stop Copy with a message suggesting the `{today...}` tokens.
  - "Same base name" means same folder on the card too, so `100CANON/IMG_0001` and
    `101CANON/IMG_0001` are two different pictures (the second gets `-2`).
  - In a set, the RAW's date wins, then the JPEG/HEIC's, then the clip's; sidecars never have
    their own. EXIF has no time zone, so it's read as the Mac's time zone.
  - When names clash, the earlier capture keeps the plain name. The `-2` applies to the whole
    set, even if only the JPEG would have clashed, so pairs stay obvious.
  - A folder "belongs to this card" if it's empty or only holds files with this card's new names
    and sizes (an interrupted copy); then it's reused with the same number. Anything else makes
    the counter skip on. With no `{iseq}` in the folder name there's no next folder, so Copy
    stops and says to add `{iseq}`.
  - Pressing Copy again after a card finished: the app finds the earlier folder from its receipt
    (same card name, same files, same new names), checks the files are there and identical, and
    doesn't use up another number. A card copied yesterday and copied again today gets a new
    folder, because it's a new day.

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

1. Install Xcode from the Mac App Store and open it once. If `swift test` says "no such module
   'XCTest'", Terminal is using the Command Line Tools instead of Xcode: either run
   `sudo xcode-select -s /Applications/Xcode.app` once, or put
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of each `swift` command.
2. In Terminal: `cd` into the project, then `swift test` (runs the tests) and
   `swift run -c release CardIngest` (opens the app; `-c release` makes copying and checksums
   much faster). Or open `Package.swift` in Xcode and press Run.
3. The app shows "Waiting for a card…", a Job panel, and the settings file path. The Job panel has:
   - **Folder name**: `{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}`, with "Next card:
     2026-10-23-ES001" (today's date) under it. Type in it and the preview changes as you type.
     Type `{jobname}` and a red message names `{jobname}` as a token it doesn't know; type
     `{year4}` and it says that one only works in file names. Undo back to the default.
   - **Next import number**: 1. Change it to 7 and the preview says ES007; set it back to 1.
   - **Copies go to**: the destination with the folder name, e.g.
     `~/Pictures/Card Ingest/2026-10-23-ES001`, with no year folder.
   - **File names**: `IMG_1234.CR3 → 2026-10-23-ES_1234.CR3` (today's date as an example).
   Choose… next to Destination and Backup picks folders; Remove clears the backup. Choose the same
   folder for Backup as Destination: a red warning appears and Copy refuses to start. Quit and
   reopen: everything is kept, and "Show in Finder" reveals `Settings.plist` with `folderName` and
   `nextImportNumber` in it (an old file's `jobName` and `folderPattern` are gone after any change).
4. `scripts/make-fake-card.sh` makes and mounts a pretend card named FAKECARD. Within a moment
   the app shows FAKECARD with "11 camera files" (MISC/SETTINGS.DAT isn't a camera file). Eject it
   in Finder and the app goes back to "Waiting for a card…".
5. Plug in any USB stick or card: it should show up too. Open "Other drives left alone": your
   Mac's own drive should be listed with the reason it was skipped.
6. With FAKECARD mounted and Next import number at 1, press Copy. It briefly says "Reading capture
   dates and choosing names…", the bar fills, then "Copied and verified 11 files" and
   "Import number 001". Next import number in the Job panel is now 2.
   "Show Imported Files" opens `2026-10-23-ES001` (today's date), with the files side by side, no
   DCIM folders:
   - `…-ES_0001.CR3` and `.JPG`, `…-ES_0001-2.CR3` and `.JPG` (the second IMG_0001, from 101TEST),
     `…-ES_0002`, `…-ES_0003` (CR3 and JPG each), `…-ES_0004.HEIC`, all with today's date
     because the fake files have no EXIF;
   - `2026-10-14-ES_0005.MP4` and `2026-10-14-ES_0005.THM`: the clip is dated 14 October and its
     thumbnail follows it.
   "Show Receipt in Finder" selects the receipt; open it in Numbers: each row has the new name,
   then the original path on the card (e.g. `DCIM/101TEST/IMG_0001.CR3`), then size and checksum.
7. Press Copy again: it finishes quickly into the same `…-ES001` folder (the files are already
   there and identical), and Next import number stays at 2.
8. Eject FAKECARD, run the script again (a new card with new random files), and set Next import
   number back to 1. Press Copy: `…-ES001` already holds the first card, so this one goes into
   `…-ES002` and the number becomes 3.
9. Press Copy and then Stop straight away: Next import number doesn't change, and pressing Copy
   again uses the same folder.
