import Foundation

public enum SyntaxLanguage: String, CaseIterable, Identifiable {
    case plain = "Plain Text"
    case swift = "Swift"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case json = "JSON"
    case html = "HTML"
    case css = "CSS"
    case markdown = "Markdown"

    public var id: Self { self }

    public static func detect(_ url: URL?) -> Self {
        switch url?.pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "json", "jsonl", "geojson": return .json
        case "html", "htm": return .html
        case "css": return .css
        case "md", "markdown", "mdown", "mkd": return .markdown
        default: return .plain
        }
    }

    public enum TokenKind: String, CaseIterable {
        case comment, quoted, keyword, number, heading, property
    }

    public struct Token {
        public let range: NSRange
        public let kind: TokenKind
    }

    public func tokens(in text: String) -> [Token] {
        let rules = patterns
        guard !rules.isEmpty else { return [] }
        let pattern = rules.map { "(?<" + $0.0.rawValue + ">" + $0.1 + ")" }.joined(separator: "|")
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        let range = NSRange(location: 0, length: text.utf16.count)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let rule = rules.first(where: { match.range(withName: $0.0.rawValue).location != NSNotFound }) else { return nil }
            return Token(range: match.range, kind: rule.0)
        }
    }

    private var patterns: [(TokenKind, String)] {
        let number = #"\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
        let doubleQuoted = #""(?:[^"\\\n]|\\.)*""#
        let singleQuoted = #"'(?:[^'\\\n]|\\.)*'"#
        let blockComment = #"/\*[\s\S]*?(?:\*/|\z)"#
        let lineComment = #"//[^\n]*"#
        switch self {
        case .plain: return []
        case .swift:
            return [
                (.comment, blockComment + "|" + lineComment),
                (.quoted, #""""[\s\S]*?(?:"""|\z)|"# + doubleQuoted),
                (.keyword, #"\b(?:import|let|var|func|struct|class|enum|protocol|extension|case|default|if|else|guard|switch|while|for|in|return|throw|throws|try|catch|do|async|await|actor|private|public|internal|static|mutating|init|deinit|self|Self|nil|true|false|some|any|where|defer|break|continue)\b"#),
                (.number, number)
            ]
        case .javascript, .typescript:
            let common = "import|export|from|let|const|var|function|class|extends|new|if|else|for|in|of|while|return|throw|try|catch|finally|async|await|true|false|null|undefined|this|super|switch|case|default|break|continue"
            let types = self == .typescript ? "|type|interface|readonly|implements|declare|public|private|protected|abstract|keyof|infer|satisfies|as|never|unknown|number|string|boolean" : ""
            return [
                (.comment, blockComment + "|" + lineComment),
                (.quoted, doubleQuoted + "|" + singleQuoted + #"|`(?:[^`\\]|\\[\s\S])*`"#),
                (.keyword, "\\b(?:" + common + types + ")\\b"),
                (.number, number)
            ]
        case .json:
            return [(.property, doubleQuoted + #"(?=\s*:)"#), (.quoted, doubleQuoted), (.keyword, #"\b(?:true|false|null)\b"#), (.number, number)]
        case .html:
            return [
                (.comment, #"<!--[\s\S]*?(?:-->|\z)"#),
                (.quoted, #"(?<==)\s*(?:"# + doubleQuoted + "|" + singleQuoted + ")"),
                (.keyword, #"</?[A-Za-z][\w:-]*|/?>|<!DOCTYPE"#),
                (.property, #"[A-Za-z_:][\w:.-]*(?=\s*=)"#)
            ]
        case .css:
            return [
                (.comment, blockComment),
                (.quoted, doubleQuoted + "|" + singleQuoted),
                (.property, #"[-A-Za-z_][-\w]*(?=\s*:\s*[^{}]*[;}])"#),
                (.keyword, #"@[\w-]+|![ \t]*important\b"#),
                (.number, #"#[\da-fA-F]{3,8}\b|"# + number)
            ]
        case .markdown:
            return [
                (.quoted, #"^[ \t]*(?:```|~~~)[^\n]*(?:\n[\s\S]*?^[ \t]*(?:```|~~~)[^\n]*|[\s\S]*\z)|`[^`\n]+`"#),
                (.heading, #"^ {0,3}#{1,6}[ \t]+[^\n]*"#),
                (.keyword, #"^ {0,3}(?:>|[-*+]|\d+\.)[ \t]+|!?\[[^\]\n]*\]\([^\n)]*\)"#),
                (.property, #"\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|_[^_\n]+_"#)
            ]
        }
    }
}
