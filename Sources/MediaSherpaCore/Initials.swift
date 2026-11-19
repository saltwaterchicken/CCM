import Foundation

/// The photographer's initials, as typed into the folder and file name
/// patterns ("ES" in …-ES{iseq} and …-ES_{frame4}). The setup tutorial
/// changes them in both at once.
public enum Initials {
    /// The letters typed just before `{iseq}` in the folder name; nil when
    /// there are none (a pattern without initials there).
    public static func current(in folderName: String) -> String? {
        guard let token = folderName.range(of: "{iseq}", options: .caseInsensitive) else { return nil }
        let letters = folderName[..<token.lowerBound].reversed().prefix { $0.isLetter }
        return letters.isEmpty ? nil : String(letters.reversed())
    }

    /// What's typed, as it goes in a name: letters and digits, capitals, at most 6.
    public static func clean(_ typed: String) -> String {
        String(typed.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(6))
    }

    /// `old` replaced by `new` in the text typed between tokens, never inside
    /// braces, and only where it stands on its own (not inside a longer word).
    public static func replace(_ old: String, with new: String, in pattern: String) -> String {
        guard !old.isEmpty else { return pattern }
        let alone = try! NSRegularExpression(pattern: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: old) + "(?![A-Za-z])")
        var result = "", literal = "", inToken = false
        func flush() {
            let range = NSRange(literal.startIndex..., in: literal)
            result += alone.stringByReplacingMatches(in: literal, range: range,
                                                     withTemplate: NSRegularExpression.escapedTemplate(for: new))
            literal = ""
        }
        for character in pattern {
            if character == "{", !inToken { flush(); inToken = true; result.append(character) }
            else if character == "}", inToken { inToken = false; result.append(character) }
            else if inToken { result.append(character) }
            else { literal.append(character) }
        }
        flush()
        return result
    }

    /// The pattern either side of the first place `initials` stand on their own
    /// in the text typed between tokens, so a window can show the pattern with
    /// just the initials editable; nil when they aren't in it.
    public static func split(_ pattern: String, at initials: String) -> (before: String, after: String)? {
        guard !initials.isEmpty else { return nil }
        let alone = try! NSRegularExpression(pattern: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: initials) + "(?![A-Za-z])")
        var literal = "", literalStart = pattern.startIndex, inToken = false
        func find() -> (before: String, after: String)? {
            guard let match = alone.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)),
                  let range = Range(match.range, in: literal) else { return nil }
            let start = pattern.index(literalStart, offsetBy: literal.distance(from: literal.startIndex, to: range.lowerBound))
            let end = pattern.index(start, offsetBy: initials.count)
            return (String(pattern[..<start]), String(pattern[end...]))
        }
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "{", !inToken {
                if let found = find() { return found }
                inToken = true
            } else if character == "}", inToken {
                inToken = false
                literal = ""
                literalStart = pattern.index(after: index)
            } else if !inToken {
                if literal.isEmpty { literalStart = index }
                literal.append(character)
            }
            index = pattern.index(after: index)
        }
        return find()
    }

    /// The settings with `new` initials in the folder and file names, or nil
    /// when the folder name has none to replace.
    public static func apply(_ new: String, to settings: IngestSettings) -> IngestSettings? {
        let new = clean(new)
        guard !new.isEmpty, let old = current(in: settings.folderName) else { return nil }
        var changed = settings
        changed.folderName = replace(old, with: new, in: settings.folderName)
        changed.renamePattern = replace(old, with: new, in: settings.renamePattern)
        return changed
    }
}
