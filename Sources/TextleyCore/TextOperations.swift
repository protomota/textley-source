import Foundation

public struct LineIndex {
    public private(set) var starts: [Int]

    public init(_ text: String) {
        starts = [0]
        for (index, codeUnit) in text.utf16.enumerated() where codeUnit == 10 {
            starts.append(index + 1)
        }
    }

    public mutating func update(in text: NSString, editedRange: NSRange, changeInLength: Int) {
        let first = line(at: editedRange.location)
        let oldEnd = editedRange.location + editedRange.length - changeInLength
        let following = line(at: oldEnd)
        var insertedStarts: [Int] = []
        for offset in editedRange.location..<NSMaxRange(editedRange) where text.character(at: offset) == 10 {
            insertedStarts.append(offset + 1)
        }
        if first == following, insertedStarts.isEmpty, changeInLength == 0 || following == starts.count {
            return
        }
        var updated = Array(starts.prefix(first))
        updated.append(contentsOf: insertedStarts)
        updated.append(contentsOf: starts.dropFirst(following).map { $0 + changeInLength })
        starts = updated
    }

    public func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }
}

public struct SearchQuery: Equatable {
    public var pattern = ""
    public var isRegex = false
    public var matchCase = false
    public var wholeWord = false
    public var wraps = true

    public init() {}

    public func expression() throws -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        let body = isRegex ? pattern : (wholeWord ? "(?<![\\p{L}\\p{M}\\p{N}_])" + escaped + "(?![\\p{L}\\p{M}\\p{N}_])" : escaped)
        let options: NSRegularExpression.Options = matchCase ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive]
        return try NSRegularExpression(pattern: body, options: options)
    }

    public func matches(in text: String) throws -> [NSTextCheckingResult] {
        try expression()?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []
    }

    public func count(in text: String) throws -> Int {
        try expression()?.numberOfMatches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? 0
    }

    public func replacementText(_ replacement: String, for match: NSTextCheckingResult, in text: String) throws -> String {
        guard isRegex, let expression = try expression() else { return replacement }
        return expression.replacementString(for: match, in: text, offset: 0, template: replacement)
    }

    public func replacingAll(in text: String, with replacement: String) throws -> (text: String, count: Int) {
        guard let expression = try expression() else { return (text, 0) }
        let mutable = NSMutableString(string: text)
        let template = isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let count = expression.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: template)
        return (mutable as String, count)
    }
}

public enum Cleanup: String, CaseIterable {
    case trim = "Trim Trailing Whitespace"
    case uppercase = "Make Uppercase"
    case lowercase = "Make Lowercase"
    case sort = "Sort Lines"

    public func edit(in text: String, selection: NSRange) -> (range: NSRange, replacement: String) {
        let source = text as NSString
        let range: NSRange
        if selection.length == 0 {
            range = NSRange(location: 0, length: source.length)
        } else if self == .trim || self == .sort {
            let first = source.lineRange(for: NSRange(location: selection.location, length: 0))
            let last = source.lineRange(for: NSRange(location: NSMaxRange(selection) - 1, length: 0))
            range = NSUnionRange(first, last)
        } else {
            range = selection
        }
        let value = source.substring(with: range)
        let replacement: String
        switch self {
        case .trim: replacement = value.replacingOccurrences(of: "[ \\t]+(?=\\n|\\z)", with: "", options: .regularExpression)
        case .uppercase: replacement = value.uppercased()
        case .lowercase: replacement = value.lowercased()
        case .sort:
            let hasFinalLineBreak = value.hasSuffix("\n")
            var lines = value.components(separatedBy: "\n")
            if hasFinalLineBreak { lines.removeLast() }
            replacement = lines.sorted().joined(separator: "\n") + (hasFinalLineBreak ? "\n" : "")
        }
        return (range, replacement)
    }
}
