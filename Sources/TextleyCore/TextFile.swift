import Foundation

public enum TextFileError: LocalizedError {
    case unsupportedEncoding, mixedLineEndings, diskChanged, openDestination

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "This file isn’t supported plain text. Textley opens UTF-8 and UTF-16 with a byte-order mark."
        case .mixedLineEndings:
            return "This file uses mixed or unsupported line endings. Textley left the original file untouched."
        case .diskChanged:
            return "Another app changed or removed this file since Textley opened or saved it."
        case .openDestination:
            return "That file is already open in Textley. Choose another destination."
        }
    }
}

public enum TextEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case utf8BOM = "UTF-8 with BOM"
    case utf16LE = "UTF-16 LE"
    case utf16BE = "UTF-16 BE"

    public var id: Self { self }

    var bom: [UInt8] {
        switch self {
        case .utf8: return []
        case .utf8BOM: return [0xef, 0xbb, 0xbf]
        case .utf16LE: return [0xff, 0xfe]
        case .utf16BE: return [0xfe, 0xff]
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        }
    }
}

public enum LineEnding: String, CaseIterable, Identifiable {
    case lf = "LF"
    case crlf = "CRLF"

    public var id: Self { self }
    var separator: String { self == .lf ? "\n" : "\r\n" }
}

public struct TextFileFormat: Equatable {
    public var encoding: TextEncoding
    public var lineEnding: LineEnding

    public init(encoding: TextEncoding = .utf8, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.lineEnding = lineEnding
    }

    public func encode(_ text: String) throws -> Data {
        let normalized = Self.normalizeLineEndings(text)
        let output = lineEnding == .lf ? normalized : normalized.replacingOccurrences(of: "\n", with: "\r\n")
        guard let bytes = output.data(using: encoding.stringEncoding) else { throw TextFileError.unsupportedEncoding }
        var data = Data(encoding.bom)
        data.append(bytes)
        return data
    }

    public static func decode(_ data: Data) throws -> (text: String, format: TextFileFormat) {
        let encoding = TextEncoding.allCases.first { !$0.bom.isEmpty && data.starts(with: $0.bom) } ?? .utf8
        let payload = data.dropFirst(encoding.bom.count)
        guard let text = String(data: payload, encoding: encoding.stringEncoding) else {
            throw TextFileError.unsupportedEncoding
        }
        var previousCR = false
        var sawLF = false
        var sawCRLF = false
        for byte in text.utf8 {
            if byte < 0x20 && byte != 9 && byte != 10 && byte != 12 && byte != 13 && byte != 27 {
                throw TextFileError.unsupportedEncoding
            }
            if previousCR && byte != 10 { throw TextFileError.mixedLineEndings }
            if byte == 10 {
                if previousCR { sawCRLF = true } else { sawLF = true }
                if sawLF && sawCRLF { throw TextFileError.mixedLineEndings }
            }
            previousCR = byte == 13
        }
        if previousCR { throw TextFileError.mixedLineEndings }
        return (sawCRLF ? normalizeLineEndings(text) : text, TextFileFormat(encoding: encoding, lineEnding: sawCRLF ? .crlf : .lf))
    }

    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(13) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

public enum TextFileAccess {
    public static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    public static func write(_ data: Data, to url: URL, replacing expected: Data? = nil, force: Bool = false,
                             exclusive: Bool = false) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result {
                if let expected, !force {
                    let current: Data
                    do {
                        current = try Data(contentsOf: coordinatedURL)
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                        throw TextFileError.diskChanged
                    }
                    guard current == expected else { throw TextFileError.diskChanged }
                }
                try data.write(to: coordinatedURL, options: exclusive ? .withoutOverwriting : .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }
}
