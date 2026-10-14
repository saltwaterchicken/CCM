# Card Ingest: Project Brief for Claude Code

You are building a small, native macOS app for a working photographer. Read this whole brief before writing any code. Then propose a plan for Milestone 1, ask any questions you need answered, and wait for my go-ahead.

## 1. What this app is

A simple, fast "front door" for a photo workflow. It is modeled on the ingest side of tools like Photo Mechanic, Lightroom's import, and ingest-verification tools like Hedge or ShotPut Pro. It is **not** an editor, browser or catalog.

The photographer inserts a card. The app copies everything off it safely, renames it, writes metadata, gives a first-pass star rating, clears the card, and ejects it. The photographer then carries on in Lightroom, Bridge, Photo Mechanic or any other editor.

**Simplicity is the top priority.** When in doubt, do less and do it reliably.

## 2. Hard requirements

- Native macOS app in **Swift 6 and SwiftUI**, targeting **macOS 14 (Sonoma) and later**, on Apple Silicon and Intel.
- **100% offline.** No network calls, no AI services, no accounts, no telemetry, no recurring costs. All image analysis uses Apple's on-device frameworks.
- Runs on any of the photographer's Macs by copying the app over. Signing and notarization can come later.
- External tools allowed: **ExifTool** (installed via Homebrew, or bundled later). Nothing else without asking me first.

## 3. The workflow, in order

1. **Detect the card.** Watch for newly mounted volumes (DiskArbitration or NSWorkspace notifications). Treat a volume as a camera card only if it is removable or ejectable media **and** contains a `DCIM` folder. Supported media include SD, CFexpress Type A/B, and anything else that mounts the same way.
2. **Copy** all photos and videos to a predetermined destination folder set in Settings. Include RAW (CR3, CR2, NEF, ARW, RAF, ORF, RW2, DNG and similar), JPEG, HEIC/HEIF, and video (MP4, MOV, MXF and similar), plus camera sidecar files such as XMP or THM. Keep RAW+JPEG pairs together.
3. **Verify** every copy by checksum against the original on the card (xxHash64 preferred, SHA-256 acceptable). Write a receipt file in the destination folder listing every file, its size and its checksum.
4. **Rename** using a pattern built from predefined fields set in Settings, for example `{date:YYYY-MM-DD}_{job}_{camera}_{seq:4}`. Available fields should include capture date and time, job name, camera model, camera serial, original filename and a sequence number. RAW+JPEG pairs and sidecars keep matching names.
5. **Write metadata** with ExifTool from a template set in Settings: creator, copyright, contact info, and per-job fields such as caption, keywords and location.
   - RAW files get an **XMP sidecar** by default and are never rewritten. Lightroom, Bridge and Photo Mechanic all read sidecars.
   - JPEG and HEIC get metadata embedded.
   - Videos get metadata embedded where ExifTool supports writing it safely, or a sidecar otherwise.
6. **Rate photos** (details in section 4). Ratings are written as the standard `XMP:Rating` so every major editor sees them.
7. **Clear the card by moving the original files to the macOS Trash.** Do **not** format or erase the card. The photographer formats in camera.
8. **Eject** the card and show a summary: files copied, verified, rated 1 star, rated 0 stars, any errors, and where the receipt is.

## 4. Star rating (first-pass culling)

This rating is a helper, not a final decision. The photographer will re-rate in their editor.

- **1 star:** the subject is in focus **and** no detected face appears to be blinking.
- **0 stars:** the subject is out of focus, **or** a detected face appears to have closed eyes.
- **No faces detected** (landscapes, products, details): rate on focus alone.
- **Videos:** not rated.
- **Sharpness:** measure it on the face regions when faces are present, otherwise on the frame's sharpest region. Laplacian variance through Core Image or Accelerate is a good starting point. For speed, analyze each RAW's embedded preview JPEG rather than decoding the full RAW.
- **Blinks:** use Apple Vision face landmarks (`VNDetectFaceLandmarksRequest`) and compute an eye-openness ratio per eye. With several faces, any clearly closed eyes on a prominent face means 0 stars.
- Keep every threshold in Settings, not hard-coded.
- Build a small **calibration tool**. It runs the scoring on a folder the photographer has already rated by hand, then reports how often the app agrees, so thresholds can be tuned against real shoots.

## 5. Safety rules (non-negotiable)

- **Nothing leaves the card until every file is copied and verified.** One mismatch, missing file or read error means the card is left untouched and the summary says why.
- **Never touch a volume that is not removable media with a `DCIM` folder.** Internal drives, backup drives and network volumes are off-limits, with no exceptions.
- **Never format, erase or partition anything.** No `diskutil erase*` calls anywhere in the codebase.
- Moving files to the Trash on a removable volume puts them in that card's own `.Trashes` folder, so they stay recoverable until the card is formatted in camera. That's acceptable and intended. The summary should note that the space frees up once the card is formatted in camera.
- Log every card processed: date, volume name, file count, destination, verification result, and whether files were trashed.
- **During development, never run against a real card.** Test with a fake card: a disk image created with `hdiutil` that contains a `DCIM` folder of sample files, then mounted.

## 6. Settings the photographer controls

- Destination folder (and an optional second backup destination).
- Rename pattern.
- Metadata template.
- Rating on or off, plus thresholds.
- Trash-after-verify on or off (default **on**, with a confirmation prompt for the first few cards).
- Auto-start on card insert, or wait for a click.

## 7. Milestones

Build in this order. Finish and test each one before starting the next, and show me how to test it.

1. **Detect, copy, verify, receipt.** Nothing is trashed or ejected yet.
2. **Rename and metadata** with ExifTool, checked by opening the results in Photo Mechanic, Lightroom or Bridge.
3. **Sharpness rating**, plus the calibration tool.
4. **Blink rating.**
5. **Trash and eject**, behind the safety rules, tested only on disk images.
6. **Settings screen, menu bar icon, card log, and polish.**

## 8. How to work with me

- I'm a photographer, not a professional developer. Explain what you're doing in plain language and tell me exactly how to test each milestone.
- Keep a `NOTES.md` in the project with decisions made, current milestone status, and open questions, so a new session can pick up where the last one left off.
- Prefer Apple frameworks over third-party packages. Ask before adding any dependency.
- Write tests for the copy, verify, rename and safety logic.
- Ask before running any command that deletes, moves or ejects anything outside the project folder or a test disk image.

## 9. Open questions to ask me before or during Milestone 1

- Which cameras and file types do I shoot most?
- What destination folder structure do I want (for example `/Photos/2026/2026-10-06_JobName/`)?
- What's my exact rename pattern today?
- What goes in my metadata template?
- Should a second backup destination be required, or optional?
