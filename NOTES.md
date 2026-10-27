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
- [x] Step 2: Star storage in `.xmp` sidecars, 1 star by default on landing (dropped 2026-10-24:
  nothing is written on landing now). Tests, then check in
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
- [x] Step 7 (asked for 2026-10-24): clips play in the large view, to scrub them in the app.
  Double-click a clip: it fills the window with a time bar at the bottom; Space plays and pauses,
  dragging the bar scrubs frame by frame, clicking the picture also plays and pauses, `,` and `.`
  step one frame back and forward (`<` `>` with Shift: ten). Space in the grid on a clip opens it and
  plays. In the grid, moving the pointer across a clip's tile scrubs it, as in Premiere (left edge
  the start, right edge the end; a line and the time show where). `ClipPlayer.swift` (AVPlayer with
  our own bar, so the keys stay with the app). Hover frames measured at 10 to 50 ms on the ES014
  clips (HEVC and H.264). Confirmed on the Mac by the photographer 2026-10-24.

**Milestone 4: Metadata template.** Started 2026-10-23 with a test of what the NAS reads, before
any code (see "Metadata"). Embedding stars in JPEG-only and HEIC shots was dropped 2026-10-23 (see
"JPEG-only and HEIC shots" under the culling grid): their copies stay exactly the card's files.

- [ ] Step 1: NAS readability test. Tag the same sample files in Bridge and in Photo Mechanic, copy
  both folders to the Synology, and record in the checklist what Synology Photos shows. Then look
  inside the tagged files to see where each app wrote the metadata.
- [ ] Step 2: Agree the spec from what the test shows, plus the photographer's template values.

**Milestone 6: Auto-rating, sharpness and exposure.** Plan written 2026-10-24
(https://claude.ai/artifact/7UMysgBFBPp1DokgpAdt81). Blinks follow as Milestone 7.

- **Answered 2026-10-26 (photographer):**
  1. Calibration folders: finished jobs, to be pulled onto this Mac (maybe later on the 26th), with
     Lightroom's ratings saved to the files (Metadata › Save Metadata to File).
  2. **A keeper is 1 star or more.** 0 never gets exported from Lightroom.
  3. **When unsure, keep.** Looking through the 0s with the filter off is fine, and a great but
     slightly soft shot can be re-rated by hand.
  4. **A sidecar for every RAW, always**, not only checked ones: 350 RAWs make 700 files, so the count
     shows the folder is complete; survivability; and keywords and other metadata will go in them.
     **Built and confirmed on the Mac 2026-10-26:** Copy writes an unrated sidecar (with the RAW's digest, and the camera's
     rating if it set one) for every RAW as it lands, whether or not auto-rating is on. A sidecar
     from the card is kept as it is. JPEG-only, HEIC and clips get none (Option A).

- **Revised 2026-10-24:** faces and no-face shots get **separate sharpness limits**
  (`minimumSharpnessFaces`, `minimumSharpnessNoFaces`): skin is smooth, so a sharp face has less edge
  contrast than sharp grass, and a landscape is never marked down for having no face. A **Job panel
  checkbox** "Rate sharpness and exposure" (`autoRating`) turns it on or off like the When done boxes.
  The checks read the copies, never the card, at lower priority than copy and verify, so the copy
  isn't slowed and trash/eject never wait for them; on a fast CFexpress card they may finish a little
  after the copy. All on-device with Apple frameworks (Vision, Accelerate/Core Image, ImageIO).
- **First calibration run (2026-10-26)**, `swift run -c release score-folder FOLDER...` (reads only;
  CSV of scores and stars). Five cards from one photographer ("AA", Photo Mechanic culls), on
  `Elliotts 3/…/KE Importing Folder/2 On Server`: 4 Nikon D5600, 1 Canon R100; 5,517 RAWs, 845 keepers
  (1★+). 130 photos/s on all cores from the external drive. Weighted lightly: one photographer, two
  entry-level cameras, and most 0s are culled for moment/expression/duplicates, not focus, so the
  measure is "keepers wrongly flagged" (aim ~1%) and "do the flagged ones look soft", never overall
  agreement.
  - **Faces: works, once adjusted for brightness** (sharpness × (128/face brightness)²; raw scores
    flagged sharp faces in shade/firelight). At ~1% of keepers: 106 of 2,645 face outtakes flagged;
    close-ups of a sample were nearly all genuinely soft or motion-blurred. The 5 keepers flagged
    were soft too, kept for the moment (one is a frame next to a flagged outtake).
  - **No faces: weaker.** ~2.6% of outtakes at ~1% of keepers; brightness adjustment didn't help.
    Dusk shots (mostly the Canon card) dominate. Needs a closer look.
  - **Exposure: no signal from clipping.** Keepers include silhouettes, firelight and stage light (up
    to 34% blown, 68% black). Clipping alone can't be a reason to flag; extremes only, or off by
    default. To discuss.
  - Per card, with these limits: 14–45 flagged per card (168 of 5,517), 0–4 of them keepers.
  - Limits differ by camera and light (median sharpness varies 3× between cards), so the
    calibration window per photographer stays essential.
- **Second run (2026-10-26), larger sample:** `Untitled/Not Backed Up/KE_MediaNAS_01_1/photo/
  Photographers/Look at` (2024 summer, ~200,000 RAWs, photographers PL, CM, ES, one AE card; Canon
  CR2/CR3, Nikon NEF; 1★ keeper / 0 outtake). Sampled ~10,000 per photographer spread across the
  summer: 28,749 RAWs, 4,141 keepers. 23 photos/s, but **ignore that speed**: per the
  photographer, this and the Sony runs were on an old archive drive. Only the first run (130/s on
  all cores) was on a real-world fast drive.
  - **Bug found and fixed:** in the first pass Vision's face search silently failed partway through
    (try? turned it into "no faces"), so most photos counted as faceless. `score` now throws when
    Vision fails. The re-run had no failures; the cause wasn't reproduced.
  - **Close-ups fooled the per-pixel measure:** big faces look smooth pixel by pixel, so sharp
    close-ups were flagged. **Fix: each face shrunk to 64 px across before measuring**
    (`faceSharpnessScaled`), times the brightness adjustment. With it, at ~1% of keepers, every
    flagged outtake in a 16-photo close-up sample was clearly soft or motion-blurred, and 9 of the
    11 flagged keepers were soft too (kept for the moment). The 2 sharp ones were big faces under
    red/pink stage light. It flags fewer outtakes than before (6% vs 9%), because the old measure
    was also catching sharp close-ups.
  - The face limit differs by photographer, so calibration per photographer stays.
  - **Decided 2026-10-26 (photographer): exposure flags extremes only**, with its own sliders in
    the calibration window. In the 28,749-photo sample keepers went up to 72% blown and 98% black, so
    proposed defaults are **over 80% blown** (0 keepers, 10 outtakes) and **over 95% black**
    (nights and silhouettes are kept; at 90% two keepers would go): blank frames, misfired flash,
    pocket shots.
- **Sony check (2026-10-26):** a Sony A1 studio headshot session (Capture One; `Camp K&E 2026/2026
  Tech/2026_0922_McKesson`, 1,072 ARWs: 85 rated 1★/3★, ~900 at 0, 80 in Trash). Not camp, so only
  the technical question. **Sony's built-in preview (1616 px) is good enough:** face scores from it
  and from decoding the full RAW at 1600 px agree almost exactly (log correlation 0.994; the preview
  reads ~14% higher, in-camera sharpening), and 44 of the lowest 51 are the same either way. The
  preview takes a few ms; decoding a 48 MP RAW ~0.8 s. Every face is sharp (lowest score 326, camp
  limits ~25–70), so nothing would be flagged, which is right; the lowest-scoring 16 were mostly from
  Trash (10 of 16, against 7% overall). Capture One keeps one `Basic_Rating` per variant in its
  `.cos` files; the last one is what it shows (matched all 983 exported JPEGs).
- [x] Step 1: Scoring in Core (RAW preview at one working size, Vision faces else sharpest area,
  Laplacian variance, blown/crushed share), tests on synthetic sharp/blurred images with and without
  faces, then a run over a hand-culled folder per camera, with timings, as a go/no-go. Sony's built-in preview is only 1616×1080 (Nikon
  and Canon embed full size, Fuji 4000×3000), so small faces may need decoding from the RAW.
- [x] Step 2: Calibration window: score a hand-rated folder once, sliders for the face, no-face and
  two exposure limits with live agreement and the misses as thumbnails, Save to the settings file.
  **Built and confirmed on the Mac 2026-10-26.** Job panel "Auto-rating" row shows the limits and a
  Calibrate… button that opens the window. Choose Folder… scores every photo once (reads only; stars
  from XMP sidecars, inside JPEGs, or a Capture One session's `.cos`). Sliders: Faces and No face on
  a log scale (1–1,000), Blown to white and Black 50–100%. Live: keepers flagged (green up to 2%,
  orange above) and outtakes flagged, counts by reason. Grid of the flagged keepers or outtakes,
  softest first, with reason chips and the score; click for a large view. Suggest sets both
  sharpness limits to flag ~1% of the folder's keepers (none with few keepers); Starting Values;
  Save to Settings / Undo Changes. Settings: `rating.autoRating` (off; the old placeholder
  `enabled` key is ignored), `minimumSharpnessFaces` 50, `minimumSharpnessNoFaces` 30,
  `maximumBlown` 0.8, `maximumCrushed` 0.95 (at 50/30, ≤1% of camp keepers flagged per photographer).
  **Dark subject (2026-10-27):** on a real card, very underexposed shots got through even with Too
  dark at its 50% end: they're dim, not pure black, and keepers go up to 98% black, so the black
  share can't catch them. Added `minimumBrightness` (0 = off, the default): the face's average
  brightness, else the sharpest area's (0 to 255), flagged "Too dark" when below it, so a lit face
  on a black stage passes. Its own "Dark subject" slider (off to 128); the two share sliders now go
  0 to 100%. Recorded as `cardingest:Brightness` in the marker. To tune on a folder with dark
  outtakes; score-folder's CSV already has `face_brightness` and `area_brightness`.
  **Labels that refine the limits (2026-10-27, asked by the photographer; confirmed on the Mac
  2026-10-27):** right-click a photo in
  the calibration window (or Label in the large view): Image Too Dark / Subject Too Dark / Image
  Too Light / Subject Too Light / Image Too Soft (no face) / Face Too Soft (with a face) / Looks
  Fine. Kept with the photo's scores in `Calibration Labels.json` beside the settings file, so they
  build up across cards over the summer. Each right-click moves only the limit it's about, the least
  it takes to flag every photo with that label, but never past flagging 1% of this folder's
  keepers, and a Looks Fine photo is always let through; anything it can't follow is listed
  ("catching it would flag 14 of your keepers here"). Not saved until Save to Settings. Learn from
  Labels redoes it; after Starting Values it's what the labels alone say (taking a label away
  doesn't loosen a limit by itself). New: `maximumBrightness` (255 = off), "Bright subject" slider
  and problem; an "Outtakes it missed" view to find the ones to label, and "Labelled".
  Learns where each line is, per settings file, not new measures or per-camera limits.
  Since then a line under the label count says what each right-click or Learn from Labels moved, or
  "No change: the limits already follow your labels" (Save stays dimmed when nothing differs from
  the saved limits, which looked like a fault).
- [ ] Step 3 (built, committed 2026-10-26; to confirm on the Mac, test step 19): Check each shot as it lands and on Load Folder (Check button): 1 star to keepers, 0
  plus a private "checked by Card Ingest" marker, scores and reason for outtakes; never a shot that
  already has stars or that's rated while it's checked. App stars look different from hand ones,
  reason chips, a Flagged filter, the Job panel checkbox.
  **Built 2026-10-26, not yet tried on the Mac.** Job panel "Rate sharpness and exposure as each
  photo lands" (`rating.autoRating`, off by default). Each photo that lands unrated is checked once
  its last file is in, on half the cores at utility priority, reading the copy; copy, trash and
  eject never wait. 1★ if it passes, 0 if not, written to its sidecar(s) in destination and backup
  with a private marker (namespace `http://ns.cardingest.app/autorating/1.0/`: Checked, Stars,
  Problems, Score, Faces, Blown, Crushed). Never a photo already rated (hand, camera or editor, 0
  included), checked again, or rated while it was being checked; the grid drops a late result too.
  Rating it here removes `cardingest:Stars`; another app changing the rating shows as a mismatch, so
  either way it counts as the photographer's. App stars are drawn blue, hand stars yellow; flagged
  tiles carry reason chips. "Check N Photos" in the grid for a loaded folder or with auto-rating
  off. Calibration leaves out photos still at the app's own stars. Tried on 35 real NEF/CR3/ARW
  copies: all checked, ~0.25 s each on one core, stars and marker read back, second run touches
  nothing.
  **Asked for 2026-10-26, built:** (1) the calibration sliders all work one way, left "Flag more",
  right "Keep more" (the sharpness ones turned round, since a lower limit keeps more), titled Soft
  faces / Soft, no face / Too bright / Too dark with a plain line each, the numbers small. (2)
  Calibrating the card just imported, while it's fresh: Calibrate… beside "Flagged by app" (or "Use
  <card>" in the window) scores that card counting the app's stars where they were left
  (`includingAppStars`), and a "Rescued by you" list shows the flagged photos the photographer
  starred, each "still flagged" or "Kept now". Check Again re-reads the card after more rating.
  **Master switch (asked for 2026-10-26):** `rating.available` in the settings file (default
  true). False removes auto-rating completely, for a slow Mac or a photographer who doesn't want it:
  no Job panel row, no checks on landing even with `autoRating` on, no Flagged by app / Check
  buttons, the calibration window says it's off; stars already written show as ordinary stars.
  **Whole-card run (2026-10-26):** two complete 2024 cards copied from the archive to the Mac's own
  disk, ratings taken out, auto-rated as after a Copy (landing sidecars, half the cores, release
  build). ES056 (209 NEF): 67 photos/s, none flagged (24 keepers). CM064 (289 CR3): 94/s, 7
  flagged: 3 frames completely out of focus, 2 dark stage faces, and 2 keepers that are soft
  (one clearly). 0 failures; reloading shows the same 7 as "Flagged by app". Copies deleted after.
  **Required (photographer, 2026-10-26): a one-click "Flagged by the app" view** in the grid's filter
  bar, with its count, showing only the photos the checks left at 0 for a quality reason (marker in
  the sidecar), not ones the photographer rated 0 by hand or hasn't rated. Each tile shows its reason
  and score, so limits can be spot-checked card by card all summer; rating one by hand there takes
  it out of the view. A link from there to Calibrate… if they look wrong.
- [ ] Step 4: Confirm on the Mac with real cards and tune.

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

**Changed 2026-10-24:** no star on landing any more (see "Decided 2026-10-24" under Metadata). Shots
arrive unrated; the checks will give **1 to keepers** and leave outtakes at 0, never touching a star
set by hand. The checks will mark the shots they've looked at, so "checked, failed" can be told from
"not checked yet". The rest of this paragraph is the earlier rule, kept for its list of checks.

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
    `.xmp`, probably a mistake). RAWs do get a sidecar on landing (since 2026-10-26), with no rating. The tile shows the rating already in the photo (as the camera or an
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
  - On landing (since 2026-10-24) nothing is written. The tile shows the stars already in the
    sidecar (from the card, or an earlier interrupted copy), else a rating set in the camera, else
    grey "not rated". A 0 from either shows as not rated, because cameras write 0 for that; the
    file keeps its 0. Load Folder reads the same way, except a 0 in a sidecar, JPEG or HEIC shows
    as 0; a RAW's own 0 (only the camera writes inside a RAW) shows as not rated.
  - Matched by name once copied, because stars change them: an `.xmp` already in the card folder is
    kept as it is (not re-verified against the card) when an interrupted copy is picked up; it
    doesn't make the folder look like another card's; and it still lets the card's original go to
    the Trash when the card goes back in.
  - The receipt lists only the card's files, so a sidecar the app made isn't in it. (The summary's
    "Stars for 9 photos are in their .xmp sidecars" went with the landing star.)
  - Not yet: marking the stars the checks give, so they never overwrite a hand rating (auto-rating).
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

**Sample folders ready (2026-10-23):** `~/Desktop/NAS Metadata Test/Bridge` and `…/PhotoMechanic`,
identical untagged copies of files already on the Mac: Sony ARW+JPG, Fujifilm RAF, Nikon NEF, Canon
CR3 (no JPEGs for those three), iPhone HEIC, camera MP4 (HEVC, timecode), Nikon MOV (HEVC), iPhone
MOV, DJI drone MP4, and `ProRes_422LT.mov` (a Premiere render). No MPEG, MXF or MTS on the Mac. The
photographer fills the checklist themselves; Claude leaves it alone until then.

**Existing Photo Mechanic template** (found in `Documents/Camp K & E consulting/2026 Notes/Media
Team/Ingesting Presets/Photo Mechanic Metadata/PM_Metadata.XMP`): keywords `Camp`, `2026`, `Summer`,
and the caption set to the rename pattern `{year4}-{month0}-{day0}-{artist}ES_{frame4}`. No
creator, copyright or location. The ingest presets in `PM_Export.pmx` (KE 2026, KE 2024, KE) use the
same folder and rename patterns Card Ingest already has. A starting point for Step 2's values.

**First results (2026-10-24),** from Card Ingest imports `2026-10-23-ES013` and `2026-10-24-ES014`
copied to the Synology (the Desktop sample folders weren't used; the checklist is still blank):
- **RAW stars: Lightroom yes, Synology Photos no**, for every brand, whether 1 from landing or a
  hand-set 2 or 3. The sidecars are right (ES014: 19 at 1, 18 at 3) and Lightroom follows them.
  Synology Photos ignores `.xmp` sidecars and reads only what's inside a file. The NEFs' own
  embedded block still says `xmp:Rating 0`.
- **Lightroom-exported JPEGs show their stars on Synology** (`•To Campanion`: 19 at 1, 18 at 3,
  embedded as `xmp:Rating` by Lightroom Classic 14.4). So Synology reads ratings embedded in a JPEG.
- **Clips:** the photographer saw no stars on the H.265 ones. Checked: none of ES014's 5 clips (2 HEVC
  MOV, 1 H.264 MOV, 2 H.264 MP4) has a rating inside it or a sidecar. Card Ingest doesn't rate clips,
  so any star shown on an H.264 clip came from somewhere other than the file (a catalog?). To ask.
- So the problem is **where** stars are stored, not the 1-star default: hand-set stars failed too.

**Decided 2026-10-24 (photographer):**
- **Option A:** the Synology is for archiving and for finding and downloading JPEGs and video. Shoots
  are almost all RAW-only. Photos reach the NAS as Lightroom exports, which carry stars and keywords
  inside; RAW stars and template fields stay in `.xmp` sidecars for Lightroom. No ExifTool, nothing
  written into RAWs or camera JPEGs.
- **Stars are a stand-in for all metadata** (keywords gave trouble on the NAS before). Synology reads
  only what's inside a file, so the real gap is **video**: clips go to the NAS without an export.
  Milestone 4 narrows to template fields in RAW sidecars plus keywords written inside MP4/MOV. Next
  test: one MP4 and one MOV with a test keyword inside, searched for on the Synology. Parked for now.
- **No 1 star on landing.** Shots arrive unrated (0); the auto-rater gives 1 to keepers, and you rate
  by hand. A private marker in the sidecar ("rated by Card Ingest") will tell the app's stars from
  yours, so it never overwrites a hand rating; downgrading from 1 could still become a setting.
  **Built and confirmed on the Mac 2026-10-24**; the marker comes with auto-rating, the first thing
  to write stars itself.

**Still to decide (Step 2):** receipt and already-imported handling once JPEG, HEIC and video are
changed after verifying (proposed: receipt keeps the card's checksum and adds the final one, those
files matched by name like `.xmp`); per-job fields in the Job panel or the settings file; the
template values themselves.

## Server backup (asked 2026-10-27, built and confirmed on the Mac 2026-10-27)

The backup goes to the Synology over a network cable. Today the backup is written in lockstep with
the main copy (each chunk to both, then both read back), so a slow NAS slows the whole copy. Asked:
1. **Backup in parallel, neither holding the other up.** Proposed: copy the card to the local drive
   as now; a second worker copies each verified local file to the NAS and verifies it there, reading
   the local copy (fast SSD), not the card, so the card is read once and the local copy runs at card
   speed. The grid, culling and auto-rating start on the local copy as now; the NAS catches up.
   To decide: trashing waits for the NAS copy to verify (safest: two verified copies before the
   card is touched; eject then waits for the NAS), or the card is trashed after the local copy and
   the NAS copies from it (faster, but one copy only until the NAS finishes).
2. **Green/red light before Copy:** NAS share mounted (the backup folder's volume is there and is a
   network volume), Wi-Fi off (CoreWLAN), wired Ethernet up (Network framework). Red says which.
   To decide: whether red blocks Copy or only warns.
3. **"Sync With Server" after culling:** copies to the NAS card folder any `.xmp` sidecar that
   changed since (stars, keywords from Lightroom's Save Metadata to File) and the
   `•To Campanion` export folder's new or changed JPEGs; never deletes on the NAS. Needs which card:
   the one in the grid, or a list of past cards (the card log, Milestone 5 Step 2).

**Decided 2026-10-27 (photographer):**
- **The card goes to the Trash once the local copy is verified,** not waiting for the NAS: budget
  photographers may be waiting on their only card. The NAS copy is made from the local copy.
- **The light only warns;** Copy still works with the cable out or the server offline.
- **Sync With Server syncs the card in the grid only**, a convenience (they've done it by hand
  before). Proposed: it also copies anything the backup missed (the RAWs, if the server was offline
  during the copy), so it doubles as catch-up.
- **Sync never deletes or shrinks the server (photographer, 2026-10-27).** Cards already dragged to
  the server may since have been deleted from the local drive; the server is the final destination.
  Rules: only adds and updates, never deletes; a file missing locally is left alone on the server;
  RAWs, JPEGs from the card and clips are never overwritten (only added if missing); only `.xmp`
  sidecars and `•To Campanion` JPEGs are updated, and only when the local one is newer; a summary
  ("adds 3, updates 412 sidecars, deletes nothing") to confirm before anything is written.

**Write-once server (raised 2026-10-27):** many photographers can create files on the server but
not change or delete them. With the backup as built today that breaks: each copy is written as a
hidden `.partial` file and renamed once verified (a rename needs change rights), a failed copy's
`.partial` is deleted (delete rights), and stars, landing sidecars and auto-rating rewrite the
sidecars in the backup (each save replaces the file). Plan for the server worker: write each file
once under its final name, then read it back to verify (no temporary name); never write stars or
auto-rating to the server during culling (local only); sidecars and `•To Campanion` JPEGs go up
with Sync With Server, created once; a file already on the server is never rewritten, and Sync
lists any it couldn't update instead of failing. A failed copy on the server can't be cleaned up,
so it's reported by name. Test with macOS ACLs on a local folder that deny delete and write to
existing files. **Confirmed 2026-10-27:** photographers can create files and folders but not
overwrite, rename or delete. Re-editing old work is rare: the admin deletes it on the server, then
the photographer's Sync puts the new versions up (they're new files again). This is deliberate, so
a junior photographer can't delete everything by mistake; the app must work within it, never ask
for more.

**Sync With Server built 2026-10-27; worked on an external USB drive, then confirmed on the server
(photographer, 2026-10-27) with a slower card, the light included.** A button at the right of the Server panel's first line, the card's name under it
(card folder shown and a backup folder set; waits while that card's backup is still sending).
Compares the card folder's own files and any `•To Campanion…` folder (subfolders too; hidden
files and Capture One's folders skipped) with its folder on the server, then shows a summary: adds
by kind (originals the backup missed, sidecars, exports), already there, and "can't update" for
files on the server that differ and are newer here (sidecars by content, big files by size), with
"Nothing on the server is deleted or replaced". Sync creates each missing file once via the
backup's write-once copier and checks it; progress and the result under the header. A server
copy newer than this Mac's is left as it is; files gone from this Mac and other cards are never
looked at; the server's own receipt isn't a conflict. Tested against a create-only folder.

**Backup worker built 2026-10-27; confirmed on the Mac with the server 2026-10-27 (the slower card
above).** The card is copied to the local
destination only; trash and eject follow that alone. With a backup folder set and its volume there
(`BackupVolume` server or drive), a `ServerBackupJob` per card sends each file as soon as the local
copy verifies it, one at a time at utility priority, from the local copy: `open(O_CREAT|O_EXCL)`
under the final name, read back and checked against the card's xxHash64; already there and
matching counts as done, a different file is left alone and listed, a bad read-back is listed for
the admin. The card's date is set if the account allows. Server receipt written once at the end,
listing only what reached it. If the server goes away the rest are listed "not sent"; if it wasn't
there at the start the card shows "Not backed up". Progress per card in the Server panel (last 5).
Stars, landing sidecars and auto-rating stay local (Load Folder no longer reaches into the backup);
they go up with Sync With Server, next. Tested against a create-only folder made with macOS ACLs
(deny delete_child, delete, writeattr), including a whole fake card the way the app runs it.

**Light built and confirmed on the Mac 2026-10-27.** Since then the Server panel always shows (grey "No backup folder" or
"Backing up to <drive>" when it isn't the server) and sits between Job and Settings File;
confirmed on the Mac 2026-10-27. A "Server" panel above the cards, shown when
a backup folder is set and isn't on a local drive: green "Wired to the server" when the backup
folder is on a mounted network share, Wi-Fi is off (CoreWLAN) and an Ethernet cable is connected
(Network framework); otherwise red, with each check and what to do. Rechecked every 3 s, the share
looked at off the main thread. Also catches a stand-in: the share not mounted but a plain folder
of its name in /Volumes on the Mac's drive, which would fill the Mac. Warning only.

## Searchable help (asked 2026-10-27, built 2026-10-27, not yet tried on the Mac)

A search field at the top of the window: as the photographer types ("trash", "stars not in
Lightroom", "server red", "blue stars"), matching answers drop down, FAQ style, each with a "Show
me" that points at the part of the window it's about (the Job panel's Backup row, the Server
light, Flagged by app, Calibrate…) with a pulsing outline, scrolling to it if needed.
Proposed: the answers are written ahead of time (by Claude, from the app and these notes, and
updated as features change), stored in the app, and searched on the Mac, so it works offline and
on any Mac. Optional later: Apple's on-device model (macOS 26 with Apple Intelligence) to answer
questions in the photographer's own words from those same answers, never made up. Also worth
doing: put the main actions in the menus too, so the standard Help menu search finds and points at
them for free. To decide: search box in the window's toolbar or the Help menu; which questions
come up most (the photographer's list from past summers).

**Live Tech Support (asked 2026-10-27):** the second row of the help drop-down, "Live Tech Support",
sends the photographer's message to the developer's WhatsApp. Two ways:
- **Simple (proposed first):** a small box in the app to type the problem; Send opens WhatsApp (app
  or web) with it already written to the support number, plus what the app knows (app version,
  the card and step it's on, the last error), shown before sending. One more tap in WhatsApp sends
  it; replies come back in WhatsApp. No server, no account, free. The number goes in the settings
  file (`supportWhatsApp`) so it can change without a new app.
  **Decided 2026-10-27: the simple way, with the latest receipt.** A WhatsApp link can carry text
  only, not a file, so: the message includes the latest receipt's summary (card, files, total size,
  verified, import number, folder), and the receipt CSV itself goes by the Mac's Share menu to
  WhatsApp (the photographer picks the support chat, already open from the link) or is shown in
  Finder to drag into the chat. To check with WhatsApp for Mac when built.
- **Fully inside the app, replies included:** needs Meta's WhatsApp Business Platform (a business
  account, a dedicated business number, approved message templates, per-conversation fees) and a
  small always-on server holding its key (a key can't ship inside the app) to pass messages both
  ways. A project of its own.

**Built 2026-10-27** (`Help.swift`, `Support.swift` in Core; `HelpView.swift`): Help › Card Ingest
Help (⌘?) opens a help window that floats over the main one: a search field, then Live Tech
Support, then 23 answers written from these notes. Typing ranks them as you go (every word counts,
half words too; "trashed", "deleted" and "erase" all mean trash; NAS/Synology mean server; question
words beat answer text) and opens the best match. Show Me brings the main window forward (out of
the large view), scrolls to the part and outlines it, pulsing, for 4 s; a part not on screen just
then says where it shows up. Help › Live Tech Support… opens the support sheet directly. The menu
bar's own Help search stays. Since then (2026-10-27) the main actions are in the menus too, so
that search finds them: File › Copy <card> (⌘↩) / Stop Copying (⌘.), Load Folder… (⌘O), Show the
card folder in Finder, Load Project Settings…, Use Default Settings, Reload Settings, Show Settings
File in Finder; a Photos menu with Open N in Lightroom, Show All Photos, Show Flagged by App, Check
Unrated Photos, Calibrate Auto-Rating…, Calibrate on This Card…, Sync With Server, each enabled
exactly when its button is. The questions are a first guess; the photographer's list from past summers will replace or
add to them.
Live Tech Support as decided: type what happened; "Sent with it" shows the app version and macOS,
the settings file, each card and its step, the last error, and the latest receipt's summary (the
newest receipt in the destination's card folders); Open in WhatsApp opens `wa.me/<number>` with it
all written; Share Receipt… (the Mac's Share menu) or Show Receipt in Finder for the file itself.
The number is built into the app by `make-app.sh` (photographer's point, 2026-10-27: they
shouldn't have to set it), from `scripts/support-whatsapp.txt` (one line, with the country code)
or `CARD_INGEST_SUPPORT_WHATSAPP`, into Info.plist as `CardIngestSupportWhatsApp`. The file is
git-ignored because the repository is public. `supportWhatsApp` in a settings file overrides it. Not yet checked with WhatsApp for Mac.

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
    Trash box, and run `scripts/make-fake-card.sh ~/Desktop/samples`. Press Copy: every RAW gets a
    `.xmp` next to it, with no stars in it (since 2026-10-26; one per RAW+JPEG pair, none for a JPEG
    on its own), so the tiles show "not rated". Give a few photos stars in the grid: their `.xmp`
    gets the number. Import the folder into
    Lightroom Classic: those RAWs show your stars, the rest none. Open the folder in Bridge or Photo
    Mechanic: the same. Change a star in Bridge,
    then open that `.xmp` in TextEdit: `<xmp:Rating>` has the new number. Known gap: Lightroom
    ignores sidecars for JPEG-only and HEIC shots (see "JPEG-only and HEIC shots").
    A card copied before the digest fix (2026-10-22-ES006) shows no stars in Lightroom; re-test with
    new pictures (a card put back in only brings in pictures it hasn't seen).
13. The culling grid (needs real photos, as in step 12; Trash unticked). Press Copy: tiles appear on
    the right as each shot lands, RAW+JPEG pairs as one tile with a "RAW+JPG" badge, each with grey
    empty stars (not rated), or the stars the camera gave. Clips show a frame, a play mark and their length, and no stars. Click a photo and
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
17. Playing clips (2026-10-24). Load Folder… a card folder with clips (e.g. `2026-10-24-ES014`, which
    has H.264 and HEVC ones). Double-click a clip: it fills the window, paused, with a bar at the
    bottom (play button, time, track, length). Press Space: it plays; Space again pauses. Drag along
    the bar: the picture follows frame by frame, and if it was playing it carries on when let go.
    Click the picture: play/pause. Paused, press `.` a few times: one frame forward each; `,` back;
    Shift-`.` jumps ten. → moves on to the next shot and the clip stops. Esc back to the
    grid, select a clip and press Space: it opens and plays straight away. On a photo, Space still
    goes to 100%. Back in the grid, move the pointer slowly across a clip's tile without clicking: the
    picture follows the pointer through the clip, a thin line along the bottom and the time in the
    corner show where, and moving off puts the first frame back.
18. Calibrating auto-rating (2026-10-26). In the Job panel, the Auto-rating row reads "Faces 50 · No
    face 30 · White 80% · Black 95%". Click Calibrate…: a second window opens. Choose Folder… and pick
    a culled job with its stars saved to the files (e.g. a card folder from `Look at`): a bar counts
    the photos as they're checked, then the summary (photos, keepers, outtakes). The grid shows the
    keepers these limits would flag, softest first; click one to see it large (Esc closes). Switch to
    "Outtakes it would flag": they should look soft. Drag Faces up: both counts rise as you drag.
    Suggest: the keepers figure goes to about 1%. Save to Settings: "Saved in Settings.plist", and the
    Job panel row shows the new numbers. Nothing in the folder changes.
19. Auto-rating (2026-10-26; real photos, Trash unticked). Tick "Rate sharpness and exposure as each
    photo lands" in the Job panel. Run `scripts/make-fake-card.sh` on a folder of real RAWs that
    includes some soft ones and press Copy: tiles appear, then "Checking sharpness and exposure: N of
    M" and stars fill in, blue for the app's. Soft ones stay at 0 with an orange "Soft face" / "Soft"
    chip. Click "Flagged by app (N)": only those show, with Calibrate… beside it. Press 1 on one: it
    turns yellow and leaves the view. In Lightroom the RAWs show 1 star or none. Untick the box,
    Load Folder… an older card: "Check N Photos" appears; click it and the same happens there, never
    to photos that already had stars.
    Then, on a card with flagged photos: in "Flagged by app" press 1 on two you'd keep, click
    Calibrate… beside it: the window opens on that card and shows "Rescued by you (2)", both "still
    flagged". Slide "Soft faces" right until they say "Kept now", watching "Your keepers flagged".
20. Server light (2026-10-27). Mount the Synology share in Finder and choose a folder on it as
    Backup in the Job panel: a "Server" panel appears above the cards. With Wi-Fi on and no cable it
    is red and says so; turn Wi-Fi off and plug in the cable: within a few seconds it turns green,
    "Wired to the server". Eject the share in Finder: red, "Server not mounted". Choose a backup on
    a USB drive instead: the light goes grey, "Backing up to <drive>". With no Backup set it is grey,
    "No backup folder". Copy works in every case.
21. Server backup (2026-10-27; fake card, Trash ticked). With the Synology mounted as Backup and the
    light green, press Copy: the tiles fill in at the usual speed and the card goes to its Trash and
    ejects as soon as the local copy is verified, while the Server panel shows "Sending to the
    server: N of M" and carries on. At the end: "All M files on the server and checked", and in
    Finder the server's card folder has the card's files and a Receipt, no hidden partial files.
    The sidecars the app made and any stars aren't there yet (Sync With Server, next). Pull the
    network cable part way through: "The server went away: N of M files reached it". Unmount the
    share and Copy another card: "Not backed up: the server wasn't connected", and the copy is
    unaffected.
22. Sync With Server (2026-10-27). After step 21, rate a few photos and export a couple of JPEGs
    from Lightroom into a `•To Campanion` folder inside the card folder. Click Sync With Server
    (right side of the Server panel, across from the light):
    the summary lists the sidecars and exported JPEGs to add, the files already there, and says
    nothing is deleted or replaced. Sync: "Synced: N files added", and Finder shows them on the
    server. Click it again: "The server already has everything". Change a star and Sync: that
    sidecar is listed under "Can't update" and the server's copy is unchanged. For a card copied
    with the server unmounted, Sync adds every file (catch-up).
