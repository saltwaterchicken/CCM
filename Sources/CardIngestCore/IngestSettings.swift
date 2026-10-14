import Foundation

/// Everything the photographer can customize, saved as one human-readable XML
/// property list. Any key left out of the file falls back to its default, so a
/// project settings file only needs the keys that differ from the defaults.
public struct IngestSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// Job name used in folder and file names, e.g. "Smith Wedding".
    public var jobName: String
    /// Where every card is copied to. `~` means your home folder.
    public var destinationRoot: String
    /// Optional second copy. Empty string means no backup.
    public var backupRoot: String
    /// Folder created inside the destination for each card.
    public var folderPattern: String
    /// File name pattern (used from Milestone 2).
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
        schemaVersion: Int = 1,
        jobName: String = "Untitled",
        destinationRoot: String = "~/Pictures/Card Ingest",
        backupRoot: String = "",
        folderPattern: String = "{date:YYYY}/{date:YYYY-MM-DD}_{job}",
        renamePattern: String = "{date:YYYY-MM-DD}_{job}_{camera}_{seq:4}",
        checksum: String = "xxh64",
        autoStartOnInsert: Bool = false,
        trashAfterVerify: Bool = true,
        confirmTrashForFirstCards: Int = 3,
        fileTypes: FileTypes = FileTypes(),
        metadata: MetadataTemplate = MetadataTemplate(),
        rating: RatingSettings = RatingSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.jobName = jobName
        self.destinationRoot = destinationRoot
        self.backupRoot = backupRoot
        self.folderPattern = folderPattern
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
        jobName = try c.decodeIfPresent(String.self, forKey: .jobName) ?? d.jobName
        destinationRoot = try c.decodeIfPresent(String.self, forKey: .destinationRoot) ?? d.destinationRoot
        backupRoot = try c.decodeIfPresent(String.self, forKey: .backupRoot) ?? d.backupRoot
        folderPattern = try c.decodeIfPresent(String.self, forKey: .folderPattern) ?? d.folderPattern
        renamePattern = try c.decodeIfPresent(String.self, forKey: .renamePattern) ?? d.renamePattern
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum) ?? d.checksum
        autoStartOnInsert = try c.decodeIfPresent(Bool.self, forKey: .autoStartOnInsert) ?? d.autoStartOnInsert
        trashAfterVerify = try c.decodeIfPresent(Bool.self, forKey: .trashAfterVerify) ?? d.trashAfterVerify
        confirmTrashForFirstCards = try c.decodeIfPresent(Int.self, forKey: .confirmTrashForFirstCards) ?? d.confirmTrashForFirstCards
        fileTypes = try c.decodeIfPresent(FileTypes.self, forKey: .fileTypes) ?? d.fileTypes
        metadata = try c.decodeIfPresent(MetadataTemplate.self, forKey: .metadata) ?? d.metadata
        rating = try c.decodeIfPresent(RatingSettings.self, forKey: .rating) ?? d.rating
    }

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
