import Foundation

/// Everything the photographer can customize, saved as one human-readable XML
/// property list. Any key left out of the file falls back to its default, so a
/// project settings file only needs the keys that differ from the defaults.
public struct IngestSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// Pattern for the folder made for each card inside the destination,
    /// e.g. `{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}` makes 2026-10-23-ES001.
    public var folderName: String
    /// The `{iseq}` the next card gets. Goes up by one after each card copies
    /// and verifies.
    public var nextImportNumber: Int
    /// Where every card is copied to. `~` means your home folder.
    public var destinationRoot: String
    /// Optional second copy. Empty string means no backup.
    public var backupRoot: String
    /// Pattern for each file's new name, without its extension.
    public var renamePattern: String
    public var checksum: String
    public var autoStartOnInsert: Bool
    public var trashAfterVerify: Bool
    /// How many cards ask for confirmation before trashing originals.
    public var confirmTrashForFirstCards: Int
    public var fileTypes: FileTypes
    public var metadata: MetadataTemplate
    public var rating: RatingSettings

    public init(
        schemaVersion: Int = 2,
        folderName: String = "{todayyear4}-{todaymonth0}-{todayday0}-ES{iseq}",
        nextImportNumber: Int = 1,
        destinationRoot: String = "~/Pictures/Card Ingest",
        backupRoot: String = "",
        renamePattern: String = "{year4}-{month0}-{day0}-ES_{frame4}",
        checksum: String = "xxh64",
        autoStartOnInsert: Bool = false,
        trashAfterVerify: Bool = true,
        confirmTrashForFirstCards: Int = 3,
        fileTypes: FileTypes = FileTypes(),
        metadata: MetadataTemplate = MetadataTemplate(),
        rating: RatingSettings = RatingSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.folderName = folderName
        self.nextImportNumber = nextImportNumber
        self.destinationRoot = destinationRoot
        self.backupRoot = backupRoot
        self.renamePattern = renamePattern
        self.checksum = checksum
        self.autoStartOnInsert = autoStartOnInsert
        self.trashAfterVerify = trashAfterVerify
        self.confirmTrashForFirstCards = confirmTrashForFirstCards
        self.fileTypes = fileTypes
        self.metadata = metadata
        self.rating = rating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IngestSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        // Milestone 1 files had jobName and folderPattern instead of folderName.
        // Those keys are ignored; their {job} and {date:...} fields no longer exist.
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? d.folderName
        nextImportNumber = max(1, try c.decodeIfPresent(Int.self, forKey: .nextImportNumber) ?? d.nextImportNumber)
        destinationRoot = try c.decodeIfPresent(String.self, forKey: .destinationRoot) ?? d.destinationRoot
        backupRoot = try c.decodeIfPresent(String.self, forKey: .backupRoot) ?? d.backupRoot
        renamePattern = try c.decodeIfPresent(String.self, forKey: .renamePattern) ?? d.renamePattern
        // Every Milestone 1 settings file was saved with this old default, which
        // was never used for renaming; move it to the new one.
        if renamePattern == Self.milestone1RenamePattern { renamePattern = d.renamePattern }
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? d.checksum
        autoStartOnInsert = try c.decodeIfPresent(Bool.self, forKey: .autoStartOnInsert) ?? d.autoStartOnInsert
        trashAfterVerify = try c.decodeIfPresent(Bool.self, forKey: .trashAfterVerify) ?? d.trashAfterVerify
        confirmTrashForFirstCards = try c.decodeIfPresent(Int.self, forKey: .confirmTrashForFirstCards) ?? d.confirmTrashForFirstCards
        fileTypes = try c.decodeIfPresent(FileTypes.self, forKey: .fileTypes) ?? d.fileTypes
        metadata = try c.decodeIfPresent(MetadataTemplate.self, forKey: .metadata) ?? d.metadata
        rating = try c.decodeIfPresent(RatingSettings.self, forKey: .rating) ?? d.rating
    }

    static let milestone1RenamePattern = "{date:YYYY-MM-DD}_{job}_{camera}_{seq:4}"

    /// The destination root with `~` expanded.
    public var destinationRootURL: URL {
        URL(fileURLWithPath: (destinationRoot as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The backup root with `~` expanded, or nil when no backup is set.
    public var backupRootURL: URL? {
        let trimmed = backupRoot.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Why the destination and backup can't be used together, or nil when they
    /// can. The backup must be a separate place, not the destination or inside it.
    public var folderProblem: String? {
        guard let backup = backupRootURL else { return nil }
        let main = destinationRootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let other = backup.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if main == other { return "The backup folder is the same as the destination. Choose a different folder, ideally on another drive." }
        if other.starts(with: main) { return "The backup folder is inside the destination. Choose a folder outside it, ideally on another drive." }
        if main.starts(with: other) { return "The destination is inside the backup folder. Choose folders that don't contain each other." }
        return nil
    }
}

/// Which file extensions count as camera files. Matching ignores case.
public struct FileTypes: Codable, Equatable, Sendable {
    public var raw: [String]
    public var photo: [String]
    public var video: [String]
    public var sidecar: [String]

    public init(
        raw: [String] = ["cr3", "cr2", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "dng", "pef", "srw", "3fr", "iiq", "x3f"],
        photo: [String] = ["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff"],
        video: [String] = ["mp4", "mov", "mxf", "m4v", "avi", "mts", "m2ts", "crm", "braw"],
        sidecar: [String] = ["xmp", "thm", "wav", "lrv", "xml"]
    ) {
        self.raw = raw
        self.photo = photo
        self.video = video
        self.sidecar = sidecar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FileTypes()
        raw = try c.decodeIfPresent([String].self, forKey: .raw) ?? d.raw
        photo = try c.decodeIfPresent([String].self, forKey: .photo) ?? d.photo
        video = try c.decodeIfPresent([String].self, forKey: .video) ?? d.video
        sidecar = try c.decodeIfPresent([String].self, forKey: .sidecar) ?? d.sidecar
    }

    /// True when the file name has one of the listed extensions.
    public func includes(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return [raw, photo, video, sidecar].contains { list in
            list.contains { $0.lowercased() == ext }
        }
    }
}

/// Metadata written to every file (used from Milestone 2).
public struct MetadataTemplate: Codable, Equatable, Sendable {
    public var creator: String
    public var copyright: String
    public var email: String
    public var phone: String
    public var website: String
    public var caption: String
    public var keywords: [String]
    public var city: String
    public var state: String
    public var country: String

    public init(
        creator: String = "", copyright: String = "", email: String = "", phone: String = "",
        website: String = "", caption: String = "", keywords: [String] = [],
        city: String = "", state: String = "", country: String = ""
    ) {
        self.creator = creator
        self.copyright = copyright
        self.email = email
        self.phone = phone
        self.website = website
        self.caption = caption
        self.keywords = keywords
        self.city = city
        self.state = state
        self.country = country
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creator = try c.decodeIfPresent(String.self, forKey: .creator) ?? ""
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        website = try c.decodeIfPresent(String.self, forKey: .website) ?? ""
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
    }
}

/// First-pass star rating (used from Milestone 3). Thresholds are starting
/// points to be tuned with the calibration tool.
public struct RatingSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Laplacian variance below this counts as out of focus.
    public var sharpnessThreshold: Double
    /// Eye-openness ratio below this counts as a blink.
    public var eyeOpennessThreshold: Double

    public init(enabled: Bool = true, sharpnessThreshold: Double = 100, eyeOpennessThreshold: Double = 0.2) {
        self.enabled = enabled
        self.sharpnessThreshold = sharpnessThreshold
        self.eyeOpennessThreshold = eyeOpennessThreshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RatingSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        sharpnessThreshold = try c.decodeIfPresent(Double.self, forKey: .sharpnessThreshold) ?? d.sharpnessThreshold
        eyeOpennessThreshold = try c.decodeIfPresent(Double.self, forKey: .eyeOpennessThreshold) ?? d.eyeOpennessThreshold
    }
}
