import Foundation
import ImageIO

/// Keywords, kept as the standard `dc:subject` list in the same `.xmp`
/// sidecar as the stars, so Lightroom, Bridge and Photo Mechanic all read
/// them. As with stars, no photo is ever rewritten, and nothing on the card is
/// touched. Clips get a sidecar of their own (C0001.MP4 gets C0001.xmp), as
/// Lightroom keeps a clip's metadata. Lightroom ignores sidecars for JPEG-only
/// and HEIC shots, the same known gap as their stars.
public enum Keywords {
    /// The keywords in a sidecar, in the order they're listed; none when it
    /// has none or doesn't exist.
    public static func read(xmp url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return [] }
        return keywords(in: metadata)
    }

    /// A shot's keywords: those in its sidecar in any destination.
    public static func found(for shot: Shot) -> [String] {
        guard shot.takesKeywords else { return [] }
        return Stars.sidecars(of: shot).lazy.map { read(xmp: $0) }.first { !$0.isEmpty } ?? []
    }

    /// Adds keywords to a shot's sidecar in every destination, making the
    /// sidecar if there isn't one. A keyword it already has, in any case, isn't
    /// added twice.
    public static func add(_ words: [String], to shot: Shot) throws {
        try change(shot) { merged($0, adding: words) }
    }

    /// Takes keywords off a shot, in every destination, whatever their case.
    public static func remove(_ words: [String], from shot: Shot) throws {
        try change(shot) { existing in words.reduce(existing) { removing($1, from: $0) } }
    }

    private static func change(_ shot: Shot, _ edit: ([String]) -> [String]) throws {
        guard shot.takesKeywords else { return }
        for (url, raw) in zip(Stars.sidecars(of: shot), Stars.raws(of: shot)) {
            let existing = read(xmp: url)
            let changed = edit(existing)
            if changed != existing {
                try Stars.write(nil, toXMP: url, raw: raw, keywords: changed)
            }
        }
    }

    /// What's typed in a keyword field: commas, semicolons or new lines
    /// between keywords, as in Photo Mechanic. Spaces at the ends are
    /// dropped, and the same keyword twice (in any case) is kept once.
    public static func parse(_ text: String) -> [String] {
        let words = text.split { $0 == "," || $0 == ";" || $0.isNewline }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return merged([], adding: words)
    }

    /// The keyword field filled in as it's typed: when the keyword being typed
    /// (after the last comma or semicolon) is the start of a known one, the
    /// text with that keyword finished, in its known case, and how much of it
    /// (in UTF-16 units, as a text field counts) was typed; the rest is what
    /// the field shows selected, so typing on replaces it. Nil when nothing
    /// fits, or the only fits are already typed earlier in the field.
    /// `known` is in order of preference, the most recently used first.
    public static func completion(of text: String, among known: [String]) -> (text: String, typedLength: Int)? {
        let start = text.lastIndex { $0 == "," || $0 == ";" }.map { text.index(after: $0) } ?? text.startIndex
        let before = String(text[..<start])
        let token = text[start...].drop { $0 == " " }
        guard !token.isEmpty else { return nil }
        let leading = String(text[start...].prefix { $0 == " " })
        let earlier = parse(before)
        guard let word = known.first(where: { word in
            word.count > token.count
                && word.lowercased().hasPrefix(token.lowercased())
                && !earlier.contains { same($0, word) }
        }) else { return nil }
        let typed = before + leading + String(word.prefix(token.count))
        return (before + leading + word, typed.utf16.count)
    }

    /// `existing` with any of `words` it doesn't already have, in any case, added at the end.
    public static func merged(_ existing: [String], adding words: [String]) -> [String] {
        var result = existing
        for word in words where !result.contains(where: { same($0, word) }) {
            result.append(word)
        }
        return result
    }

    /// `existing` without `word`, in any case.
    public static func removing(_ word: String, from existing: [String]) -> [String] {
        existing.filter { !same($0, word) }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    static func keywords(in metadata: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path),
              let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let text = value as? String { return parse(text) }
        guard let items = value as? [Any] else { return [] }
        let words = items.compactMap { item -> String? in
            if let text = item as? String { return text }
            if CFGetTypeID(item as AnyObject) == CGImageMetadataTagGetTypeID() {
                return CGImageMetadataTagCopyValue(unsafeBitCast(item as AnyObject, to: CGImageMetadataTag.self)) as? String
            }
            return nil
        }
        return merged([], adding: words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    /// Replaces the keyword list in `metadata`; an empty list takes it out.
    static func set(_ words: [String], in metadata: CGMutableImageMetadata) -> Bool {
        CGImageMetadataRemoveTagWithPath(metadata, nil, path)
        guard !words.isEmpty else { return true }
        guard let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                 "subject" as CFString, .arrayUnordered, words as CFArray) else { return false }
        return CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
    }

    private static var path: CFString { "dc:subject" as CFString }
}
