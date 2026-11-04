import Foundation

/// A part of the main window a help answer can point at.
public enum HelpTarget: String, CaseIterable, Sendable {
    case cards, folderName, importNumber, destination, backup, keywords, whenDone, autoRating
    case server, syncWithServer, settingsFile
    case loadFolder, starFilter, flaggedByApp, openIn, checkPhotos

    /// What "Show me" calls it, and where to look when it isn't showing.
    public var place: String {
        switch self {
        case .cards: "the card at the top left (it shows once a card is in)"
        case .folderName: "Folder name in the Job panel"
        case .importNumber: "Next import number in the Job panel"
        case .destination: "Destination in the Job panel"
        case .backup: "Backup in the Job panel"
        case .keywords: "Keywords in the Job panel"
        case .whenDone: "When done in the Job panel"
        case .autoRating: "Auto-rating in the Job panel"
        case .server: "the light in the Server panel"
        case .syncWithServer: "Sync With Server in the Server panel (it shows once a card is copied or loaded and a backup folder is set)"
        case .settingsFile: "the Settings File panel"
        case .loadFolder: "Load Folder… above the grid"
        case .starFilter: "the star filter above the grid (it shows once there are photos)"
        case .flaggedByApp: "Flagged by app above the grid (it shows once photos have been checked)"
        case .openIn: "the Open button above the grid (it shows once there are photos)"
        case .checkPhotos: "the Check button above the grid (it shows for photos with no stars yet)"
        }
    }
}

/// A command in the app's own menus, as the help window lists it: found by
/// typing, and run from there.
public struct MenuCommand: Identifiable, Sendable, Equatable {
    /// Where it is among the menus read, so the window can run that item.
    public let id: Int
    /// The menu it's in ("Photos").
    public let menu: String
    public let title: String
    /// As the menu shows it ("⌘↩"); empty when it has none.
    public let shortcut: String
    public let enabled: Bool

    public init(id: Int, menu: String, title: String, shortcut: String = "", enabled: Bool = true) {
        self.id = id
        self.menu = menu
        self.title = title
        self.shortcut = shortcut
        self.enabled = enabled
    }
}

/// One answer, written ahead of time from how the app works.
public struct HelpAnswer: Identifiable, Sendable, Equatable {
    public let id: String
    public let question: String
    public let answer: String
    /// Other words someone might type for it.
    public let keywords: [String]
    public let target: HelpTarget?

    public init(_ id: String, _ question: String, _ answer: String, keywords: [String] = [], target: HelpTarget? = nil) {
        self.id = id
        self.question = question
        self.answer = answer
        self.keywords = keywords
        self.target = target
    }
}

public enum Help {
    /// Searches as the photographer types. Every word counts, even half
    /// typed; answers matching more of the words come first, with matches in
    /// the question ahead of matches in the text. Nothing typed lists them all.
    public static func search(_ query: String, in answers: [HelpAnswer] = Help.answers) -> [HelpAnswer] {
        let words = Self.words(query, droppingStopWords: true)
        guard !words.isEmpty else { return answers }
        let ranked = answers.enumerated().compactMap { index, answer -> (answer: HelpAnswer, matched: Int, score: Int, index: Int)? in
            let question = Set(Self.words(answer.question)), keywords = Set(answer.keywords.flatMap { Self.words($0) }),
                text = Set(Self.words(answer.answer))
            var matched = 0, score = 0
            for word in words {
                let found = { (set: Set<String>) in set.contains(word) || (word.count >= 3 && set.contains { $0.hasPrefix(word) }) }
                let weight = found(question) ? 3 : found(keywords) ? 2 : found(text) ? 1 : 0
                if weight > 0 { matched += 1; score += weight }
            }
            return matched > 0 ? (answer, matched, score, index) : nil
        }
        return ranked.sorted { ($0.matched, $0.score, -$0.index) > ($1.matched, $1.score, -$1.index) }.map(\.answer)
    }

    /// The menu commands that every typed word finds, in the command's name or
    /// its menu's, with name matches first. Nothing typed finds none, so the
    /// answers aren't pushed down by a list of every command.
    public static func search(_ query: String, in commands: [MenuCommand]) -> [MenuCommand] {
        let words = Self.words(query, droppingStopWords: true)
        guard !words.isEmpty else { return [] }
        let ranked = commands.enumerated().compactMap { index, command -> (command: MenuCommand, score: Int, index: Int)? in
            let title = Set(Self.words(command.title)), menu = Set(Self.words(command.menu))
            var score = 0
            for word in words {
                let found = { (set: Set<String>) in set.contains(word) || (word.count >= 3 && set.contains { $0.hasPrefix(word) }) }
                if found(title) { score += 2 } else if found(menu) { score += 1 } else { return nil }
            }
            return (command, score, index)
        }
        return ranked.sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }.map(\.command)
    }

    /// A menu item's shortcut as the menu shows it: ⌃⌥⇧⌘ then the key.
    public static func shortcut(key: String, control: Bool = false, option: Bool = false, shift: Bool = false,
                                command: Bool = false) -> String {
        guard !key.isEmpty else { return "" }
        let named: [String: String] = ["\r": "↩", "\u{1b}": "⎋", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7f}": "⌫"]
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (named[key] ?? key.uppercased())
    }

    /// Lowercased words, each cut to a plain stem and a shared name for its
    /// synonyms, so "trashed", "deleted" and "Trash" all find the same answer.
    static func words(_ text: String, droppingStopWords: Bool = false) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { !droppingStopWords || !stopWords.contains(String($0)) }.map { word in
            var w = String(word)
            if w.count > 4, w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
            else if w.count > 4, w.hasSuffix("ied") { w = String(w.dropLast(3)) + "y" }
            else if w.count > 5, w.hasSuffix("ing") { w = String(w.dropLast(3)) }
            else if w.count > 4, w.hasSuffix("ed") { w = String(w.dropLast(2)) }
            else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w = String(w.dropLast()) }
            return synonyms[w] ?? w
        }
    }

    static let stopWords: Set<String> = ["a", "an", "the", "is", "are", "do", "does", "i", "my", "me", "how", "what", "why",
                                          "to", "it", "of", "in", "on", "can", "when", "where", "be", "this", "that", "and", "or",
                                          "with", "for", "get", "there", "you", "your", "not", "no", "won", "t", "don", "isn", "aren"]

    static let synonyms: [String: String] = [
        "nas": "server", "synology": "server", "network": "server",
        "delete": "trash", "delet": "trash", "erase": "trash", "eras": "trash", "bin": "trash", "remov": "trash", "remove": "trash",
        "rating": "star", "rat": "star", "rate": "star",
        "lr": "lightroom", "lrc": "lightroom",
        "picture": "photo", "image": "photo", "pic": "photo", "shot": "photo",
        "sd": "card",
        "blurry": "soft", "blur": "soft", "focu": "soft", "sharp": "soft", "sharpness": "soft",
        "underexpos": "dark", "underexposed": "dark", "black": "dark",
        "overexpos": "bright", "overexposed": "bright", "white": "bright", "blown": "bright", "light": "bright",
        "duplicate": "already", "twice": "already", "again": "already",
        "counter": "number", "iseq": "number",
        "folder": "folder", "rename": "name", "filename": "name",
        "wifi": "wi", "ethernet": "cable", "wire": "cable", "wir": "cable",
        "calibration": "calibrate", "calibrat": "calibrate",
    ]

    public static let answers: [HelpAnswer] = [
        HelpAnswer("license", "How do I enter or renew my license key?",
                   "Help › License… shows who the app is licensed to and until when. To renew, paste the new key from the "
                   + "email (it starts with CI1-) after Enter New Key…, and press Activate. A reminder shows at the top of the "
                   + "window from 14 days before the end. Without a working key, copying cards and Sync With Server are off, but "
                   + "photos already copied can still be opened and rated, and a copy already running always finishes. The key "
                   + "is checked on this Mac alone: no internet is needed. If it says the clock is wrong, set the right date in "
                   + "System Settings › General › Date & Time.",
                   keywords: ["key", "activate", "renew", "expired", "unlock", "licence", "subscription"]),
        HelpAnswer("copy", "How do I copy a card?",
                   "Put the card in. It shows at the top left with how many camera files it has. Press Copy (or File › Copy, ⌘↩). "
                   + "Every file is copied, "
                   + "then read back and checked against the card before anything else happens. Thumbnails fill the grid as each "
                   + "photo lands, so you can start rating straight away.",
                   keywords: ["import", "start", "ingest"], target: .cards),
        HelpAnswer("not-seen", "My card doesn't show up",
                   "Any removable drive counts as a card, with or without a DCIM folder. A card in a fast reader (CFexpress or XQD) can "
                   + "look like an ordinary external drive to the Mac, so it counts once it has a camera's folders. A drive with "
                   + "none (a Blackmagic or RED card, or one no camera has formatted) shows a Use as Card button instead. The app leaves alone the Mac's own drive, "
                   + "network drives, and any drive holding the destination or backup folder. Open \"Other drives left alone\" under "
                   + "the cards to see each drive it skipped and why.",
                   keywords: ["missing", "detect", "inserted", "ignored", "usb"], target: .cards),
        HelpAnswer("card-readers", "Why does my card say Copy only?",
                   "The reader decides, not the card. In a USB reader or the Mac's SD slot a card reads as removable, so it copies, "
                   + "goes to its Trash and ejects, as you've set under When done. A CFexpress or XQD card in a PCIe or Thunderbolt "
                   + "reader looks just like a fixed drive to the Mac, so it copies and ejects but nothing goes to its Trash, in case it "
                   + "really is a drive. The card says \"Copy only\" in orange before you start. Format it in the camera once your "
                   + "copies are safe. A card with no DCIM folder, or a locked one, says it too.",
                   keywords: ["cfexpress", "xqd", "compactflash", "cf", "cfast", "reader", "thunderbolt", "pcie", "orange", "stay", "stayed", "kept", "full", "not cleared"],
                   target: .cards),
        HelpAnswer("use-as-card", "How do I use a Blackmagic or RED card?",
                   "These cards have no camera folders for the app to recognize, so in a PCIe or Thunderbolt reader they don't show as "
                   + "cards by themselves. Under the cards, press Use as Card beside the drive. You press it each time the card goes "
                   + "in, so a working drive is never taken for a card; Not a Card undoes it. They copy and eject, but nothing goes "
                   + "to their Trash. RED files keep the camera's names, because a long clip's pieces rely on them.",
                   keywords: ["blackmagic", "bmpcc", "braw", "red", "r3d", "komodo", "cinema", "choose", "manual", "select"],
                   target: .cards),
        HelpAnswer("mxf", "Why is there no sound in my MXF clip?",
                   "Macs can't open MXF clips the usual way, so the app reads their pictures itself: you see thumbnails, scrub in the "
                   + "grid and the large view, and play them, with no sound. It's there to check clips by eye; the sound is safe in "
                   + "the copy and plays in Premiere. Intra clips move frame by frame. Long GOP clips, which only hold a complete "
                   + "picture now and then, move in steps (half a second on Canon), and the bar says so. Log footage looks flat and dim, as "
                   + "it does before grading. MOV and MP4 clips play with sound as usual. An MXF that isn't H.264 (MPEG-2, for one) "
                   + "shows no picture here yet, but copies just the same.",
                   keywords: ["mxf", "audio", "silent", "mute", "preview", "scrub", "thumbnail", "log", "flat", "dim", "xf-avc", "canon", "gop", "choppy", "jumpy", "steps"],
                   target: nil),
        HelpAnswer("settings-file-list", "What can I change by editing the settings file?",
                   """
                   In the Settings File panel, Show in Finder finds the file; open it in a text editor. Keep a copy first, as a typo can stop it \
                   loading. Press Reload right after saving, or your next change in the app will overwrite the edit. Any key you leave out goes back to its default.

                   ONLY IN THE FILE
                   • autoStartOnInsert: a camera card with new files starts Copy when it goes in (default false)
                   • keepClipsOnCardUntilOnServer: clips stay out of the card's Trash until Save to Clips has put them on the Server (default false)
                   • openWith: the app the Open button sends photos to (default Adobe Lightroom Classic)
                   • renamePattern: the pattern for new file names (default {year4}-{month0}-{day0}-ES_{frame4}); the tutorial's initials step can change the initials in it
                   • confirmTrashForFirstCards: how many more cards ask before originals go to the Trash (default 3)
                   • rating › available: false removes auto-rating from the app completely (default true)
                   • supportWhatsApp: replaces the built-in Live Tech Support number (default empty)
                   • notifications › server: the ntfy server for phone alerts (default https://ntfy.sh)
                   • notifications › topic: the private topic for phone alerts; they stay off until it's set (default empty)
                   • fileTypes › raw, photo, video, sidecar: which file extensions count as camera files, and of what kind (default: built-in lists)

                   ALSO CHANGED IN THE APP
                   • folderName, nextImportNumber, metadata › keywords: the Job panel
                   • destinationRoot, backupRoot: the Choose… buttons
                   • trashAfterVerify, ejectWhenDone, rating › autoRating: the Job panel's checkboxes
                   • rating › minimumSharpnessFaces, minimumSharpnessNoFaces, maximumBlown, maximumCrushed, minimumBrightness, maximumBrightness: Calibrate

                   IN THE FILE, BUT DOING NOTHING
                   • checksum (always xxHash64) and rating › eyeOpennessThreshold
                   • metadata › creator, copyright, email, phone, website, caption, city, state, country
                   • schemaVersion: leave this one alone
                   """,
                   keywords: ["settings", "plist", "edit", "editing", "change", "modify", "manually", "hand", "keys", "options", "list"],
                   target: .settingsFile),
        HelpAnswer("auto-start", "Can a card start copying as soon as it goes in?",
                   "Yes. In the settings file, set autoStartOnInsert to true, then press Reload. A card with camera folders and new files then "
                   + "starts Copy by itself when it goes in while the app is open, and Trash and eject follow as they're ticked under When done. "
                   + "The first 3 cards still ask before anything goes to the Trash. A card already imported, one that was in before the app "
                   + "opened, and one you press Use as Card for all wait for you.",
                   keywords: ["automatic", "automatically", "auto", "autostart", "insert", "start", "by itself", "without clicking"],
                   target: nil),
        HelpAnswer("red-preview", "Why don't my RED clips show a picture?",
                   "Macs can't read RED's R3D files, so these clips have no thumbnail or scrubbing here. Their tiles say so, and you "
                   + "preview them in Premiere or REDCINE-X. The copy is checked like any other. RED splits a long take into many files of "
                   + "about 4 GB, and each shows as its own tile, matching the card.",
                   keywords: ["red", "r3d", "redcine", "komodo", "preview", "scrub", "thumbnail", "picture", "blank", "pieces", "tiles"],
                   target: nil),
        HelpAnswer("trash", "Where did the photos on my card go?",
                   "With \"Move the card's photos and videos to the card's Trash\" ticked under When done, each original goes to the "
                   + "card's own Trash once every copy is verified. Nothing is erased: they stay there until you format the card in "
                   + "the camera, which is when the space frees up. The first 3 cards ask first. Untick the box to leave cards as they are. "
                   + "A card marked \"Copy only\" stays as it is either way.",
                   keywords: ["trash", "delete", "empty", "gone", "missing", "format", "space", "free"], target: .whenDone),
        HelpAnswer("eject", "Why didn't my card eject?",
                   "The card ejects after the copy (and the trash, if that's on) when \"Eject the card when finished\" is ticked. "
                   + "If a Finder window or another app is using the card, macOS won't let it go: the summary says so and the card "
                   + "stays. Close the other window and eject it in Finder. Nothing is ejected after a failed copy.",
                   keywords: ["stuck", "unmount"], target: .whenDone),
        HelpAnswer("already", "It says the card was already imported",
                   "The app reads the receipts in your destination's card folders. A file listed there with the same place on the "
                   + "card, size and date counts as imported, so putting a card back in copies only what's new, into a new folder "
                   + "with the next import number. With nothing new, nothing is copied and the number isn't used up. Deleting a whole "
                   + "card folder, receipt included, lets that card be imported again.",
                   keywords: ["skip", "skipped", "partly", "nothing new", "same card"], target: .cards),
        HelpAnswer("number", "How do I change the import number (ES007)?",
                   "Type it in Next import number in the Job panel. It's the {iseq} in the folder name and goes up by one only after "
                   + "a card copies and verifies, so a failed or stopped copy doesn't use one up. If the next folder already exists "
                   + "from another card, it skips to the next free number.",
                   keywords: ["sequence", "es", "wrong number"], target: .importNumber),
        HelpAnswer("folder-name", "How are card folders named?",
                   "Folder name in the Job panel is a pattern, e.g. {todayyear4}-{todaymonth0}-{todayday0}-ES{iseq} makes "
                   + "2026-10-23-ES001. The line under it shows the next card's folder as you type. Each card's folder goes straight "
                   + "inside the destination.",
                   keywords: ["pattern", "token", "date", "initials"], target: .folderName),
        HelpAnswer("file-names", "How are files renamed?",
                   "Each file gets the rename pattern from the settings file, by default {year4}-{month0}-{day0}-ES_{frame4}: the "
                   + "date it was taken and the camera's frame number, e.g. 2026-10-14-ES_1234.CR3. RAW+JPEG pairs and sidecars keep "
                   + "the same name. If two files would get the same name, the later one gets -2. Nothing is ever overwritten. "
                   + "\"File names\" in the Job panel shows an example.",
                   keywords: ["frame", "-2", "clash"], target: .folderName),
        HelpAnswer("where", "Where do my copies go?",
                   "Destination in the Job panel, ~/Pictures/Card Ingest unless you change it. \"Copies go to\" shows the exact "
                   + "folder the next card will make. After a copy, Show Imported Files opens it.",
                   keywords: ["destination", "location", "find", "path"], target: .destination),
        HelpAnswer("backup", "How does the backup work?",
                   "Choose a backup folder in the Job panel, ideally on the server or another drive. The card is copied to the "
                   + "destination at full speed; each verified file is then sent on to the backup from that copy, so a slow server "
                   + "never holds up the card. The card can go to the Trash once the destination copy is verified. The Server panel "
                   + "shows each card's progress.",
                   keywords: ["second copy", "slow"], target: .backup),
        HelpAnswer("server-light", "Why is the server light red?",
                   "Green means the backup folder is on a mounted network share, Wi-Fi is off and an Ethernet cable is in. Red lists "
                   + "which of those isn't right and what to do. It only warns: Copy still works, and a backup that couldn't reach the "
                   + "server says \"Not backed up\", so you can catch up later with Sync With Server.",
                   keywords: ["red", "green", "offline", "wi", "cable", "mounted", "connect"], target: .server),
        HelpAnswer("sync", "How do I send stars and exports to the server?",
                   "Press Sync With Server in the Server panel (or Photos › Sync With Server). It covers every card listed "
                   + "there, plus the card in the grid (to sync an older card, Load Folder it first); the names under the button "
                   + "say which. A card still backing up is left until its backup finishes. It shows, card by card, what it "
                   + "will add first: sidecars with your stars, "
                   + "JPEGs in a •To Campanion folder inside the card folder, and any originals the backup missed. Nothing on the "
                   + "server is deleted or replaced. A file already on the server that's different here is listed under "
                   + "\"Can't update\"; ask the admin to remove it there, then Sync again.",
                   keywords: ["upload", "campanion", "export", "sidecar", "catch up", "can't update", "both", "cards", "all"],
                   target: .syncWithServer),
        HelpAnswer("rate", "How do I rate photos?",
                   "Click a photo in the grid, then press 0 to 5. With one photo selected it moves on to the next. Arrows move "
                   + "around, ⌘A selects all. Double-click or press Space for a large view, Space again for 100% to check focus, "
                   + "Esc to go back. Clips are rated the same way; their stars go in a .xmp of their own beside the clip.",
                   keywords: ["keys", "keyboard", "cull", "zoom", "100%", "clip", "video"], target: .starFilter),
        HelpAnswer("keywords", "How do I add keywords?",
                   "Type the job's keywords in Keywords in the Job panel, with commas between (Camp, 2026, Summer): every photo "
                   + "gets them as it lands. For a few photos, select them in the grid, press K, type keywords with commas between and "
                   + "press Return (a keyword used before fills itself in: Tab or a comma takes it); the grid takes the keys back so you can carry on rating. The bar under the grid "
                   + "shows the selection's keywords: × takes one off, a dim one is only on some (click it to add it to all), and "
                   + "Recent adds one you used lately in one click. ⌘K shows and hides the bar. The job's keywords are in the "
                   + "settings file; the ones you add in the grid are yours, kept in My Keywords.txt (File › Show My Keywords in "
                   + "Finder), one per line, to edit by hand if you like. Keywords go in the same .xmp sidecar as the stars, which "
                   + "Lightroom, Bridge and Photo Mechanic read; the photos themselves are never changed. Clips take keywords too, in a "
                   + ".xmp of their own beside the clip. The arrows still move in the grid while you type.",
                   keywords: ["keyword", "tag", "tags", "metadata", "subject", "my keywords", "autofill", "recent"], target: .keywords),
        HelpAnswer("save-to-clips", "How do clips get their stars and keywords into Premiere?",
                   "With a backup folder set, clips wait on this Mac when a card is copied; photos go to the Server as usual. Rate and "
                   + "keyword the clips in the grid, then press Save to Clips: it writes the stars and keywords inside each clip, where "
                   + "Premiere Pro reads them, then sends it to the Server. The picture and sound aren't touched, and a clip with "
                   + "nothing to add goes as it is. Do it before the clips go up, as the Server's copy can't be changed afterwards. "
                   + "The Server panel lists cards with clips still waiting, and your phone is told after a day. The Server's own photo "
                   + "viewer doesn't show keywords from inside a clip. MXF, MTS and AVI can't hold them, so they stay in the .xmp beside the clip. "
                   + "Clips clear from the card with everything else; to keep them on the card until they're on the Server, set "
                   + "keepClipsOnCardUntilOnServer to true in the settings file.",
                   keywords: ["premiere", "video", "clip", "embed", "save to clips", "server", "waiting", "keepclipsoncarduntilonserver"], target: .keywords),
        HelpAnswer("burst", "What does the green Subject Sharpest chip mean?",
                   "It marks the sharpest frame of a burst: three or more frames, each taken within a second of the one before. "
                   + "Frames with a face are judged on the largest face, as that's most likely the subject; a "
                   + "burst with no face, on the sharpest part of the picture. It only points the frame out: no stars are given "
                   + "or taken. It shows on cards copied since 2026-10-30, on photos the sharpness and "
                   + "exposure checks have looked at (with auto-rating off, press Check N Photos first). If even the sharpest is soft, it has the orange chip too.",
                   keywords: ["burst", "sharpest", "green", "chip", "subject", "frames", "sequence", "continuous"]),
        HelpAnswer("lightroom", "My stars don't show in Lightroom",
                   "Stars for RAW photos are in the .xmp sidecar next to each file, which Lightroom reads when it imports. For photos "
                   + "already in Lightroom, select them and choose Metadata › Read Metadata from Files. JPEG-only and HEIC photos "
                   + "are a known gap: Lightroom ignores sidecars for them (Photo Mechanic and Bridge read them). Open in Lightroom "
                   + "above the grid, or Photos › Adjust Raw Images, sends the photos shown.",
                   keywords: ["missing", "xmp", "sidecar", "read metadata", "jpeg", "adjust"], target: .openIn),
        HelpAnswer("blue-stars", "Why are some stars blue?",
                   "Blue stars were given by the app's sharpness and exposure check; yellow ones by you. 1 blue star is a keeper, 0 "
                   + "means it was flagged, with the reason on the tile. Rating a photo yourself replaces the app's stars, and the "
                   + "app never changes a photo that already has stars.",
                   keywords: ["yellow", "colour", "color", "auto"], target: .flaggedByApp),
        HelpAnswer("flagged", "What does \"Flagged by app\" show?",
                   "Only the photos the check left at 0 for being soft or badly exposed, each with its reason. Rate one you'd keep "
                   + "and it drops out. If too many good ones are there, Calibrate… beside it lets you tell the app where it's wrong.",
                   keywords: ["flag", "0", "zero", "reason", "auto"], target: .flaggedByApp),
        HelpAnswer("auto-rating", "How do I turn auto-rating on or off?",
                   "Tick or untick \"Rate sharpness and exposure as each photo lands\" in the Job panel. When on, each photo with no "
                   + "stars gets 1 if it passes and 0 if it's soft or badly exposed. Photos from a loaded folder, or copied with it "
                   + "off, can be checked with the Check button above the grid.",
                   keywords: ["sharpness", "exposure", "automatic", "check"], target: .autoRating),
        HelpAnswer("calibrate", "Too many good photos are flagged (or bad ones missed)",
                   "Calibrate on a card you've culled: Calibrate… in the Job panel (or Photos › Calibrate on Another Card…). The grid "
                   + "then shows every photo with the orange chips the limits would give it, and the sliders take the place of the Job "
                   + "panel. Where a chip is wrong, right-click the photo (or use Label in the large view, at 100% to judge focus): "
                   + "Looks Fine on a flagged one, or what's wrong with one that isn't (Too Dark, Face Too Soft…). The limits move to "
                   + "follow straight away, never so far that they'd flag more than 1 in 100 of your keepers, and your disagreements "
                   + "add up over the summer. Sort by score to see the borderline ones together, or in shooting order to compare "
                   + "frames. Save to Settings keeps the limits; Done Calibrating goes back.",
                   keywords: ["calibrate", "limit", "slider", "label", "dark", "soft", "bright", "wrong", "learn", "disagree", "train"], target: .autoRating),
        HelpAnswer("load", "How do I get back to an earlier card?",
                   "Load Folder… above the grid (or File › Load Folder…, ⌘O) opens a card folder from an earlier import with its "
                   + "stars, without the card: after "
                   + "a restart or on another day. If the backup has the same folder, stars you give are saved there too.",
                   keywords: ["earlier", "yesterday", "reopen", "restart", "previous", "old"], target: .loadFolder),
        HelpAnswer("failed", "The copy failed or I pressed Stop",
                   "Nothing on the card is changed after a failed or stopped copy, and copies that weren't verified are removed. "
                   + "File › Stop Copying (⌘.) stops one. Press Copy again: it picks up in the same folder, and the import number isn't used up until it finishes. "
                   + "Photos already rated keep their stars.",
                   keywords: ["error", "stop", "interrupted", "crash", "resume", "space"], target: .cards),
        HelpAnswer("receipt", "What is the receipt?",
                   "A spreadsheet (CSV) saved in each card folder listing every file copied, its size, its checksum and that it "
                   + "was verified, with a summary at the end. It's how the app knows what's already imported. Show Receipt in "
                   + "Finder after a copy finds it; Live Tech Support can send it.",
                   keywords: ["csv", "checksum", "verify", "proof", "log"], target: .cards),
        HelpAnswer("settings", "How do I use different settings for a project?",
                   "Load Project Settings… in the Settings File panel uses another settings file; every change in the window is "
                   + "saved to the file in use, including its import number. Use Default goes back. Calibration labels are kept "
                   + "beside each settings file.",
                   keywords: ["project", "plist", "default", "reload", "file"], target: .settingsFile),
        HelpAnswer("tutorial", "How do I go through the setup steps again?",
                   "Choose Help › Setup Tutorial…. It walks through your initials, the destination, the server backup, the card "
                   + "counter and what happens when a card is done, and saves each choice as you go. It opens by itself only the "
                   + "first time Card Ingest runs on a Mac.",
                   keywords: ["tutorial", "setup", "start", "first", "walkthrough", "guide", "welcome", "initials"]),
        HelpAnswer("initials", "How do I change my initials in the names?",
                   "Help › Setup Tutorial… changes them in both the folder name and the file names at once, with a preview. "
                   + "Or edit Folder name in the Job panel; the file names follow the rename pattern in the settings file.",
                   keywords: ["initials", "es", "name", "letters"], target: .folderName),
        HelpAnswer("notifications", "How do I get alerts on my iPhone or Watch?",
                   "Install the free ntfy app on the iPhone and subscribe to this Mac's topic: a long name nobody would guess, like "
                   + "a password. Help › Setup Tutorial… makes one and copies it, to paste into ntfy (tap +) or text to yourself. "
                   + "It's kept in the settings file under notifications › topic. Then choose Help › Send Test Notification. If "
                   + "ntfy lists the messages but the phone gives no alerts, delete ntfy, install it again and subscribe again. You'll be told when a card is copied, when its backup is on the "
                   + "server, and when Sync With Server is done. The Watch shows them when the iPhone passes on ntfy's alerts. "
                   + "Leave the topic empty to turn them off.",
                   keywords: ["notification", "alert", "phone", "iphone", "watch", "ntfy", "push", "done", "finished", "topic", "test"]),
        HelpAnswer("support", "How do I reach tech support?",
                   "Choose Live Tech Support at the top of this window. Type what happened; the app adds its version, the card "
                   + "and the latest receipt's summary, and opens WhatsApp with it all written. One more tap sends it, and the reply "
                   + "comes back in WhatsApp.",
                   keywords: ["help", "contact", "whatsapp", "message", "problem", "bug"]),
    ]
}
