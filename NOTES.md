# Card Ingest: working notes

Keep this file current so any new session can pick up where the last one left off.
The full brief is `BRIEF.md`.

## Status

**Milestone 1: Detect, copy, verify, receipt.** In progress.

- [x] Step 1: Project skeleton, settings file with defaults, fake-card script, CI.
- [x] Step 2: Detect any removable card or drive and show it. Confirmed on the Mac with a real SD card.
- [x] Step 3: Copy, verify with xxHash64, write the receipt. Tests for copy and verify. Confirmed on the Mac.
- [ ] Step 4: Test on the photographer's Mac.

**Milestone 2: Folder and file naming.** Spec agreed 2026-10-23 (see "Naming" below). Built and
tested; waiting for the photographer to try it with a real card.

- [x] Step 1: Token patterns (`{todayyear4}`, `{iseq}`, `{frame4}`, ...) in NameTemplate, with tests.
- [x] Step 2: "Job name" becomes "Folder name" holding the pattern; import counter in settings and the
  Job panel; card folder `2026-10-23-ES001`; counter goes up after each successful import.
- [x] Step 3: Read each file's capture date and frame number; rename files on copy; tests.
- [x] Already imported files are skipped when a card goes back in (see "Already imported").
  Confirmed on the Mac 2026-10-22 (steps 6 to 8 of "How to test what exists so far").
- [ ] Step 4: Receipt shows original name next to new name (done, tested). Confirm on the Mac with a
  real card (not yet).

**Milestone 3 (new): Live culling grid with star rating.** Agreed 2026-10-23, ahead of metadata
and auto-rating (see "Culling grid"). **Done**, confirmed by the photographer 2026-10-23.

- [x] Step 1: Copier reports each file as it's verified; files grouped by shot (RAW+JPEG+sidecars). Tests.
  `CardCopier.copy(fileVerified:)` and `ShotList` in `Shots.swift`; nothing on screen yet (Step 4).
- [x] Step 2: Star storage in `.xmp` sidecars, 1 star by default on landing. Tests, then check in
  Lightroom, Bridge or Photo Mechanic. Confirmed in Lightroom Classic 2026-10-22 with a Sony RX100
  card (after the RAW digest fix below), then with Nikon NEF, Canon CR3 and Fujifilm RAF files
  copied from a card: all showed 1 star.
- [x] Step 3: Thumbnail maker (embedded RAW preview, JPEG/HEIC, video frame), background and cached.
  `Thumbnails.swift`; nothing on screen until Step 4.
- [x] Step 4: Grid in the main window filling live during Copy; selection, 0 to 5 keys, auto-advance.
  `Culling.swift` in Core, `CullingView.swift` in the app. Confirmed on the Mac with a real card,
  2026-10-23.
- [x] Step 5: Larger view (double-click), Space for 100%, arrows, star filter. Plus (asked for
  2026-10-23) an Open button sending photos to Lightroom Classic, Load Folder…, Reveal in Finder,
  and up/down arrows. Confirmed on the Mac 2026-10-23.
- [x] Step 6: Confirm on the Mac. Confirmed with real cards 2026-10-23; the slow fake card option
  wasn't needed and wasn't built.

**Milestone 4: Metadata template.** Started 2026-10-23 with a test of what the NAS reads, before
any code (see "Metadata"). Embedding stars in JPEG-only and HEIC shots was dropped 2026-10-23 (see
"JPEG-only and HEIC shots" under the culling grid): their copies stay exactly the card's files.

- [ ] Step 1: NAS readability test. Tag the same sample files in Bridge and in Photo Mechanic, copy
  both folders to the Synology, and record in the checklist what Synology Photos shows. Then look
  inside the tagged files to see where each app wrote the metadata.
- [ ] Step 2: Agree the spec from what the test shows, plus the photographer's template values.

**Milestone 5: Trash and eject.** Started early at the photographer's request, 2026-10-22, while
Milestone 2's metadata waits on the template. Built and tested on disk images; not yet tried on the Mac.

- [ ] Step 1: "When done" checkboxes in the Job panel: move the originals to the card's Trash, and
  eject the card (see "Trash and eject"). Confirm on the Mac with the fake card.
- [ ] Step 2: Card log (every card: date, name, file count, destination, verified, trashed). The brief
  lists it under Milestone 6.

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
  `.Trashes`) and other file types are skipped. So is the camera's own index (decided 2026-10-22,
  after an RX100 card's `MEDIAPRO.XML` was copied as `…-ES_0000.XML`): inside Sony's `M4ROOT` (and
  `XDROOT` on pro cameras) only `CLIP` and `SUB` count, so `MEDIAPRO.XML`, `STATUS.BIN`,
  `CUEUP.XML` and the clip thumbnails in `THMBNL` are never copied or trashed
  (`CardScanner.isCameraIndex`). A folder that can't be read stops
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
  - Pressing Copy again after a card finished, or putting the card back in: see "Already
    imported" below.

## Already imported (asked for 2026-10-23)

The photographer put the same card back in and it was copied again. Now only files no earlier
import brought in are copied (`ImportHistory.swift`):

- **How the app knows:** it reads the receipts in every card folder directly inside the
  destination. A card file counts as already imported when a receipt lists the same path on the
  card, the same size and the same modified date. Receipts now have an "Original Modified"
  column for this; receipts from before it (no column) match on path and size alone.
  Card name doesn't matter, because most cards are called EOS_DIGITAL or Untitled.
- **Modified dates:** cards keep them to 2 seconds, and FAT cards store local time, so after the
  Mac changes time zone the same file looks whole hours off. Both still count as the same file.
  A reformatted card whose new IMG_0001 happens to have the same size but was taken at another
  time is a new file.
- **When the card is shown,** before Copy is pressed, an orange line says e.g. "Partly imported
  before: 120 of 142 files are already in 2026-10-23-ES001. Copy brings in the 22 new files only."
  or "Already imported: all 142 files are in 2026-10-23-ES001. Nothing new to copy."
- **Copy with some new files:** only the new ones are copied, into a new card folder with the next
  import number (the earlier folder is left as it is). The done message adds "Skipped 120 files
  already imported earlier." The receipt lists only the files copied this time.
- **Copy with nothing new:** nothing is read or copied, no receipt is written, the import number
  isn't used up, and Show Imported Files opens the folder they're in.
- **Culling:** deleting rejects from an imported folder doesn't bring them back next time, because
  the receipt still lists them. Deleting a whole card folder (with its receipt) lets that card be
  imported again.
- An interrupted copy writes no receipt, so its files aren't "already imported"; Copy picks up in
  the same folder as before.
- Only the destination is checked, not the backup.

## Trash and eject (asked for 2026-10-22)

Two checkboxes under "When done" in the Job panel, saved as `trashAfterVerify` and `ejectWhenDone`
(both on by default, as the brief says). `CardClearer.swift` decides what may be trashed;
the app only asks and shows the result.

- **Trash:** after Copy has verified every file, each camera file with a safe copy is moved to the
  card's own Trash (its hidden `.Trashes` folder), never erased, so it's recoverable until the card
  is formatted in the camera. "Safe copy" means verified by this Copy, or brought in by an earlier
  import and still in that card folder at the same size. So a card put back in is cleared too, and a
  reject already deleted from the imported folder stays on the card. Copy pressed with nothing new
  still clears the card. Files that aren't camera files (`MISC/SETTINGS.DAT`) and the folders stay.
- **Checked again just before each move:** the file is still on the card with the size and modified
  date it had when copied. A file that fails this, or won't move, stays and is listed; the rest go.
- **Asks first** for the first 3 cards (`confirmTrashForFirstCards`, which goes down by one at each
  "Move to Trash"): "Move the 11 originals on FAKECARD to the card's Trash?" with Move to Trash /
  Keep on Card. After that it trashes without asking.
- **Only camera cards:** a drive without a `DCIM` folder (a USB stick, a backup drive) is copied
  from but never trashed, and a locked SD card is left alone; the summary says why. This settles the
  open question about USB drives.
- **Eject:** after the copy (and trash, if on) the card is ejected. It disappears from the list and
  its summary stays on screen under "Ejected. You can take the card out." until Dismiss. If eject
  fails (a Finder window or another app is using the card), the summary says so and the card stays.
  Nothing is ejected after a failed copy.
- Not yet: the receipt doesn't record trashing, and there's no card log.

## Culling grid (Milestone 3, agreed 2026-10-23)

Like Photo Mechanic's ingest: thumbnails appear as each file lands, and the photographer can view
larger and rate straight away instead of waiting for the whole card. The order of the remaining
milestones is now: 3 culling grid, 4 metadata template (ExifTool), 5 sharpness and exposure rating
plus calibration, 6 blink rating, then settings/menu bar/polish. Trash and eject was built early.

**Star rule (the photographer's call, 2026-10-23):** every photo gets **1 star** the moment it lands.
**0 stars is reserved for the automatic checks**: subject out of focus, badly overexposed, badly
underexposed, or a blinking face. So a 0 always means "the app flagged this". The auto-rating
milestones only ever move a photo from 1 down to 0, never touch a star set by hand, and keep every
threshold in Settings. Exposure is new (not in the brief) and joins the sharpness milestone.
Videos get no star.

What the photographer sees and does:

- Press Copy and a grid fills in under the progress bar, one tile per **shot** as soon as its files
  are copied and verified. A shot is the files sharing a base name: RAW+JPEG show as one tile with a
  small "RAW+JPG" badge. Videos show a frame, a play icon and the duration, and can't be rated.
- Each tile shows its stars. Click, Shift-click and Cmd-click select.
- **Keys, matching Photo Mechanic:** number keys 0 to 5 set the stars on the selection. With one
  photo selected, setting a star **moves on to the next photo** automatically. Left and right arrows
  move between photos.
- **Double-click** a tile for a full-window view. Arrows, number keys and auto-advance work there too.
  **Space toggles 100%** (actual pixels) to check focus; drag to pan. Esc goes back to the grid.
- A small filter: All, 1 star and up, 0 stars (the flagged ones), and so on.
- The grid shows the card just copied (only files this Copy brought in; already-imported files are
  skipped as now) and stays up until the next card. It reads only the verified copies in the
  destination, never the card, so trash and eject work exactly as before.

How it works:

- **File landed:** `CardCopier.copy` gains a per-file report, called once a file is verified and has
  its final name in every destination (not for `.partial` files). The app adds or updates the tile.
  Built 2026-10-22: `fileVerified` runs on the copying thread, once per file, before the receipt is
  written; files already there from an interrupted copy are reported too, and files verified before a
  failure have already been reported. `ShotList.add` groups copies by new base name, ignoring case
  (the planner gives a RAW+JPEG pair and its sidecars one base name, and `-2` twins stay separate).
  A shot's tile file is its RAW, else JPEG/HEIC, else clip; the badge lists the picture files
  (`RAW+JPG`, sidecars don't count); its stars go in the `.xmp` from the card if there is one.
  Shots keep the order their first file landed.
- **Thumbnails and preview:** ImageIO's `CGImageSourceCreateThumbnailAtIndex` pulls the camera's
  embedded JPEG out of the RAW without decoding it; JPEG and HEIC open directly; a video frame comes
  from AVFoundation. Made on a background queue, only for tiles on screen, and cached, so a
  2,000-file card doesn't slow the copy. The full-window view uses the largest embedded preview. For
  100%, if the embedded preview is smaller than the sensor, decode the RAW itself with Core Image
  (`CIRAWFilter`). All Apple frameworks, no new dependency.
  Built 2026-10-22 (`ThumbnailMaker`, `ThumbnailCache`), measured on the photographer's files:
  - RAWs use the camera's built-in preview: 10 to 60 ms for a 400-pixel tile from Sony ARW, Nikon
    NEF, Canon CR3 and Fuji RAF, against 100 to 500 ms to decode the RAW. The tile looks like the
    camera's JPEG (a black-and-white picture style shows black and white), as in Photo Mechanic.
  - A JPEG's built-in thumbnail is only 160 pixels, so anything smaller than the tile is drawn from
    the full image instead (20 to 35 ms). Small images aren't enlarged; turned photos stand upright.
  - A RAW this Mac can't read (a camera newer than macOS knows) falls back to the shot's JPEG; a clip
    that won't open falls back to its `.THM`. Clips show a frame 1 second in (or halfway, if
    shorter), plus their length.
  - The cache makes 3 at a time at low priority, shares one when two tiles ask at once, skips a tile
    that scrolled away before its turn, and keeps about 128 MB (around 300 tiles), dropping the
    least recently shown first. It reads only the copies in the destination.
  Step 4 as built: the window has two columns, the card, Job and Settings panels on the left and the
  grid on the right. A tile appears when its shot's last file is verified and its first star is
  written (a moment after the first file), so a star key can never race the camera's `.xmp` landing.
  Keys only work after clicking a tile (that gives the grid the keyboard; typing in the Job panel
  takes it back). Stars are written on one queue in the order given. A new Copy that brings in files
  clears the grid; Copy with nothing new, a failed copy and eject leave it.
  Step 5 as built (2026-10-23):
  - Double-click a tile, or press Space in the grid (opens straight at 100%), for a view filling the
    window. Space switches between fitted and 100%; clicking a spot in the fitted picture shows that
    spot at 100%; drag to look around. Arrows, 0 to 5 and auto-advance work there; Esc goes back.
    The 100% spot stays put from photo to photo, to compare a burst.
  - 100% is one image pixel per screen pixel. A RAW's built-in preview is used when it's full size
    (Nikon, Fuji measured), otherwise the RAW is decoded with Core Image (`CIRAWFilter`; Sony ARW
    270 ms, Canon CR3 320 ms measured). So a Sony shot in a black-and-white picture style shows
    black and white fitted (the camera's preview) and colour at 100% (the RAW).
  - Filter buttons: All, ★1+ ... ★5, 0★. Clips only show with All. Clicks, keys and ⌘A act on the
    shots shown; rating one out of the filter hides it and moves on.
  - "Open N in Adobe Lightroom Classic" sends the selected photos, or everything shown when nothing
    is selected, one file per shot (the RAW of a pair). The app is `openWith` in the settings file
    (name, bundle id or path; default "Adobe Lightroom Classic"), not shown in the window.
  - Fixed after the photographer's first try (2026-10-23):
    - **Open crashed the app** every time (macOS then relaunched it). macOS reports back on a
      thread of its own, and Swift 6 had assumed the callback ran on the main thread, so its check
      stopped the app (crash reports in `~/Library/Logs/DiagnosticReports/CardIngest-*.ips`). The
      callback is now marked `@Sendable`; so is the eject one, to be safe.
    - **Up and down arrows** move a row in the grid (the grid counts its tiles per row).
    - **The large view was slow.** It was decoding the whole Sony RAW (400 to 500 ms) because the
      camera's preview (1,616 pixels) is smaller than the screen. Now a preview at least 0.45 of the
      screen's size is used as it is (13 ms). The grid's tile shows at once instead of a black screen,
      then sharpens; the next and previous photos (and the next one's 100% picture, at 100%) load
      ahead. Large pictures are kept up to 384 MB; 100% pictures, the one showing and the next.
    - **Load Folder…** (top of the grid, always there) brings an earlier card folder back into the
      grid with its stars, after a crash or another day, without the card. When the backup has a
      folder of the same name, its copies are included, so stars given now are saved in both.
    - **Reveal in Finder** (asked for 2026-10-23): Control-click or right-click a tile; Finder opens
      the card folder with that shot's files selected (RAW, JPEG and sidecar).
- **Where stars go:** `XMP:Rating` (`xmp:Rating`) in a sidecar `<new base name>.xmp` next to the
  shot, in the destination and the backup alike, written atomically. One sidecar per shot, so a
  RAW+JPEG pair shares it. RAW files are never rewritten. A small hand-written XMP packet is enough
  for now; the metadata milestone (ExifTool) adds the template fields to the same sidecar.
- **JPEG-only and HEIC shots** (a JPEG or HEIC with no RAW; the photographer's call, 2026-10-23):
  - The app never writes into a JPEG or HEIC, so every copy keeps the card's checksum, and import,
    receipt, already-imported, resume and trash work as for any file. Tested 2026-10-23: ImageIO can
    set a JPEG's rating without re-compressing, but it rewrites the EXIF block too (re-rounded
    values), which risks a camera's maker notes. Not worth it on originals.
  - **No star on import:** nothing is written for them when they land (they used to get a 1-star
    `.xmp`, probably a mistake). The tile shows the rating already in the photo (as the camera or an
    editor set it, a 0 counting as unrated), else grey empty stars for "not rated".
  - **Load Folder** reads the shot's sidecar if there is one, else the rating embedded in the photo,
    as it is: Capture One and Lightroom write `xmp:Rating` inside a JPEG, not in a sidecar. A 0
    there shows as 0. Checked on an exported Capture One folder (242 JPEGs: 13 at 1, 229 at 0).
  - A number key still writes a `.xmp` sidecar (the JPEG is untouched). Known gap: Lightroom
    ignores sidecars for JPEG and HEIC, so it won't see stars given here (Photo Mechanic and Bridge
    do).
  - Grey empty stars (not rated) only show with the All filter; the 0★ filter shows only real 0s.
- **A sidecar that came off the card:** if the camera wrote an `.xmp` with the same base name, update
  its rating inside it instead of replacing it. Already-imported and trash must still recognise that
  file afterwards (its size changes), so treat `.xmp` files as matched by name, not size.
- **In-camera ratings:** if the photo already carries a rating set in the camera (read with ImageIO),
  keep it instead of the 1-star default.
- **Built 2026-10-22** (`Stars.swift`, decided while building):
  - Sidecars are read and written with ImageIO's XMP support (`CGImageMetadata`), not by hand, so a
    camera's sidecar keeps all its other fields and any prefix it used for the rating is understood.
    Written atomically. Unreadable sidecars are left alone and listed in the summary.
  - A shot gets its stars when its **last** file is verified, not its first: the camera's `.xmp`
    sorts after the CR3 and JPG, and a sidecar made earlier would have collided with it.
  - On landing, stars already in the sidecar win (from the card, or an earlier interrupted copy),
    then a rating set in the camera, then 1. A 0 from either counts as "not rated", because cameras
    write 0 for that. Known gap: a hand-set 0 in an interrupted copy comes back as 1 on re-copy.
  - Matched by name once copied, because stars change them: an `.xmp` already in the card folder is
    kept as it is (not re-verified against the card) when an interrupted copy is picked up; it
    doesn't make the folder look like another card's; and it still lets the card's original go to
    the Trash when the card goes back in.
  - The summary says "Stars for 9 photos are in their .xmp sidecars". The receipt lists only the
    card's files, so a sidecar the app made isn't in it.
  - Not yet: telling a hand-set star from the landing 1, which the auto-rating milestones need.
  - **Lightroom needs the RAW's digest** (found 2026-10-22 with a Sony RX100 card: Lightroom showed
    no stars). Many RAWs (Sony ARW, Nikon, DNG, Canon CR3) carry their own XMP block inside, Sony's
    saying `xmp:Rating 0`. Lightroom and Camera Raw only trust a sidecar over it when the sidecar's
    `photoshop:EmbeddedXMPDigest` is the MD5 of that block; otherwise they take the RAW's 0 and ignore
    the sidecar. So a RAW shot's sidecar now also gets that digest (`RawXMP.swift`: tag 700 of a
    TIFF-style RAW, or the XMP `uuid` box of a CR3), `photoshop:SidecarForExtension` and
    `xmp:MetadataDate`, as Adobe writes them.
  - Per brand (checked on files on the photographer's Mac, 2026-10-22): Sony ARW and Nikon NEF match
    the digests Lightroom itself wrote. Canon CR3 keeps the block (`Rating 0`) in the XMP `uuid` box;
    Fujifilm RAF keeps it in the XMP section of the preview JPEG inside the RAF (pointer at byte 84).
    All four showed 1 star in Lightroom Classic after a Copy from a card (2026-10-22).
- **If the copy fails part way:** stars already given stay in the sidecars next to the verified
  copies; the card is untouched, as now. The tiles stay so the photographer can keep culling.

Not in this milestone: colour labels, tags, captions, rejecting or deleting from the grid, browsing
older imports.

## Metadata (Milestone 4, started 2026-10-23)

**Leaning: Apple frameworks, no ExifTool.** The photographer's call: the app should copy to any Mac
and just work, without a Homebrew install. The brief allowed ExifTool, but nothing needs it:
- RAW (all brands): fields go in the `.xmp` sidecar the stars already use (ImageIO). RAWs are never
  rewritten.
- JPEG, HEIC: embedded with ImageIO without recompressing. HEIC still to be checked.
- MP4, MOV, ProRes: an XMP block appended to the end of the file, the way Adobe writes it. Video
  and audio untouched. Apple's own route (AVAssetExportSession) re-saves the whole video, which is
  slow and can drop camera data such as timecode, so we'd write the small block ourselves.
- MXF, MTS/M2TS, MPG, AVI: `.xmp` sidecar. ExifTool can't write into these either.
Not final until Step 1's test confirms the NAS reads it.

**Why test first:** in the past, video metadata written by Photo Mechanic wasn't readable on the
Synology NAS, but metadata written by Adobe Bridge was. So before building, find out exactly what
Synology Photos reads, for every camera and video format, and copy whatever works.
(btrfs, the NAS's file system, only stores the files; what matters is what Synology Photos reads.)

**The test (Step 1):**
1. One or two files of each kind the photographer shoots: RAW+JPEG from Sony, Fuji, Nikon and
   Canon; an iPhone HEIC; MP4; MPEG; QuickTime MOV; ProRes; MXF or MTS if any camera makes them.
2. Two copies of the folder, "Bridge" and "PhotoMechanic".
3. Tag every file the same way in each app: caption `TEST BRIDGE` or `TEST PM`, keyword
   `cardtest`, creator, copyright, a city, 3 stars.
4. Copy both folders to the NAS the usual way, let Synology Photos index them, and record which
   fields show for each file in the "NAS Metadata Checklist" artifact (its data can be read back
   with ArtifactData, collection `files`).
5. Keep the tagged folders on the Mac. Claude inspects each file and sidecar to see where each app
   wrote what, and why the NAS missed Photo Mechanic's.

**Still to decide (Step 2):** receipt and already-imported handling once JPEG, HEIC and video are
changed after verifying (proposed: receipt keeps the card's checksum and adds the final one, those
files matched by name like `.xmp`); per-job fields in the Job panel or the settings file; the
template values themselves.

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

- ~~Sony's `MEDIAPRO.XML` copied like a photo~~ Decided 2026-10-22: skipped (see Scanning).

- ~~Because any removable drive counts, USB drives are offered as cards: what about trashing?~~
  Decided 2026-10-22: only drives with a `DCIM` folder are trashed (see "Trash and eject").
- Should the app be called CCM instead of Card Ingest?

- Which cameras and file types are shot most? (Defaults cover Canon, Nikon, Sony, Fuji,
  Olympus/OM, Panasonic, Pentax, Leica DNG, plus common video.)
- Metadata template values (needed for Milestone 4). Rename pattern is decided, see Naming.

## How to test what exists so far

1. Install Xcode from the Mac App Store and open it once. If `swift test` says "no such module
   'XCTest'", Terminal is using the Command Line Tools instead of Xcode: either run
   `sudo xcode-select -s /Applications/Xcode.app` once, or put
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of each `swift` command.
2. In Terminal: `cd` into the project, then `swift test` (runs the tests) and
   `swift run -c release CardIngest` (opens the app; `-c release` makes copying and checksums
   much faster). Or open `Package.swift` in Xcode and press Run.
   To open it by double-click instead, run `scripts/make-app.sh` once: it builds
   "CCM Card Ingest.app" into /Applications (drag it to the Dock if you like). Run it again
   after pulling new code to update the app.
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
7. The card now shows an orange "Already imported: all 11 files are in …-ES001. Nothing new to
   copy." Press Copy: nothing is copied, it says so, and Next import number stays at 2. Eject
   FAKECARD and mount it again with `hdiutil attach TestCards/FAKECARD.dmg`: same message.
   Add a file (`head -c 300000 /dev/urandom > /Volumes/FAKECARD/DCIM/100TEST/IMG_0006.JPG`),
   eject FAKECARD in Finder and attach it again: it says "Partly imported before: 11 of 12 files…
   Copy brings in the 1 new file only." Press Copy: only IMG_0006 goes into a new `…-ES002`,
   "Skipped 11 files already imported earlier", and Next import number is 3.
8. Eject FAKECARD, run the script again (a new card with new random files), and set Next import
   number back to 1. Press Copy: `…-ES001` and `…-ES002` already hold the first card, so this one
   goes into `…-ES003` and the number becomes 4.
9. Press Copy and then Stop straight away: Next import number doesn't change, and pressing Copy
   again uses the same folder.
10. Trash and eject, on the fake card only. Steps 6 to 9 assume both "When done" boxes are off;
    tick both now. A tip line under the first box says "Asks first for the next 3 cards".
    Eject FAKECARD if it is in, and run the script. Press Copy: after
    "Copied and verified 11 files" it asks "Move the 11 originals on FAKECARD to the card's Trash?".
    Press Keep on Card: the card ejects, the summary says "You chose to keep the originals on the
    card.", and the tip still says 3. Run `hdiutil attach TestCards/FAKECARD.dmg` and press Copy:
    nothing new, and it asks again for the 11. Press Move to Trash: "Moved 11 originals to the card's
    Trash", "Ejected. You can take the card out.", and the tip says 2. Attach the image again:
    "0 camera files", and `ls /Volumes/FAKECARD/.Trashes/*` lists the 11 originals; `MISC` is still there.
11. Untick "Eject the card when finished". Run the script again and press Copy: it trashes without
    asking once the tip has counted down to 0, otherwise press Move to Trash. The card stays listed
    with the summary. Locked card: eject FAKECARD, run the script again, eject it in Finder, run `hdiutil attach -readonly
    TestCards/FAKECARD.dmg`, and press Copy: "The card is locked (check the switch on its side), so
    nothing was moved to the Trash."
12. Stars in an editor (needs real photos; the fake card's random bytes won't open in Lightroom).
    Put a few RAW+JPEG pairs from your camera in a folder, e.g. `~/Desktop/samples`, untick the
    Trash box, and run `scripts/make-fake-card.sh ~/Desktop/samples`. Press Copy: the summary says
    "Stars for N photos are in their .xmp sidecars". In the card folder each photo has a `.xmp`
    next to it (one per RAW+JPEG pair). Import the folder into Lightroom Classic: the RAWs show
    1 star. Open the folder in Bridge or Photo Mechanic: 1 star there too. Change a star in Bridge,
    then open that `.xmp` in TextEdit: `<xmp:Rating>` has the new number. Known gap: Lightroom
    ignores sidecars for JPEG-only and HEIC shots (see "JPEG-only and HEIC shots").
    A card copied before the digest fix (2026-10-22-ES006) shows no stars in Lightroom; re-test with
    new pictures (a card put back in only brings in pictures it hasn't seen).
13. The culling grid (needs real photos, as in step 12; Trash unticked). Press Copy: tiles appear on
    the right as each shot lands, RAW+JPEG pairs as one tile with a "RAW+JPG" badge, each with one
    yellow star. Clips show a frame, a play mark and their length, and no stars. Click a photo and
    press 3: it gets 3 stars and the next photo is selected. Press 0: it shows five empty orange
    stars. Shift-click and Cmd-click select several; a number rates them all and stays put. ⌘A
    selects all. ← → move along. Import the folder into Lightroom: it shows the stars you gave.
14. Looking closer, filtering, opening. After step 13: double-click a photo, it fills the window.
    Press Space: 100%, with "100%" in yellow at the top (a second or so for a big RAW). Drag to look
    around; press → and the next photo shows the same spot. Press Space to fit, click on an eye:
    100% there. Press 3: 3 stars, next photo. Esc: back to the grid. Press Space in the grid: straight
    to 100%. Give a few photos 0, then choose ★1+: they disappear, and so do clips. With nothing
    selected, the button says "Open N in Adobe Lightroom Classic" for all shown; click it: Lightroom
    comes up with those photos to import. In the settings file, set `openWith` to `Adobe Bridge 2023`
    and Reload: the button says Bridge. Set it back.
15. After the fixes of 2026-10-23: in the grid, ↑ ↓ move a row. Open in Lightroom no longer
    crashes Card Ingest. The large view shows the photo straight away and → is instant. Quit Card
    Ingest, open it again, press Load Folder… and pick an earlier card folder: its photos come back
    with the stars you gave them; change one, then import that folder in Lightroom to see it.
16. JPEG-only shots (2026-10-23). Put a few JPEGs with no RAW on the fake card and press Copy: their
    tiles show grey empty stars (or the camera's rating), and no `.xmp` appears next to them. Then
    press Load Folder… and pick a folder of JPEGs exported from Capture One or Lightroom with stars:
    the tiles show the same stars as Capture One or Lightroom. Choose 0★: the grey ones aren't in it.
