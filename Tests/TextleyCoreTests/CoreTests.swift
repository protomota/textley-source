import Foundation
import TextleyCore
import XCTest

final class CoreTests: XCTestCase {
    func testSupportedFilesRoundTripExactly() throws {
        let original = "Cafe\u{0301} 👩🏽‍💻\nlast"
        for encoding in TextEncoding.allCases {
            for ending in LineEnding.allCases {
                let format = TextFileFormat(encoding: encoding, lineEnding: ending)
                for source in [original, original + "\n"] {
                    let data = try format.encode(source)
                    let decoded = try TextFileFormat.decode(data)
                    XCTAssertEqual(Array(decoded.text.utf8), Array(source.utf8))
                    XCTAssertEqual(decoded.format, format)
                    XCTAssertEqual(try decoded.format.encode(decoded.text), data)
                }
            }
        }
        let utf8BOM = Data([0xef, 0xbb, 0xbf, 0xc3, 0xa9])
        XCTAssertEqual(try TextFileFormat.decode(utf8BOM).text, "é")
        XCTAssertThrowsError(try TextFileFormat.decode(Data([0xff, 0x00, 0xc0])))
        XCTAssertThrowsError(try TextFileFormat.decode(Data("first\r\nsecond\n".utf8)))
        XCTAssertThrowsError(try TextFileFormat.decode(Data("first\rsecond".utf8)))
    }

    func testSaveConflictAndFailedWriteKeepOriginalIntact() throws {
        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("draft.txt")
        let base = Data("original".utf8)
        let other = Data("external change".utf8)
        let edit = Data("my edit".utf8)
        try TextFileAccess.write(base, to: file)
        try other.write(to: file)
        XCTAssertThrowsError(try TextFileAccess.write(edit, to: file, replacing: base))
        XCTAssertEqual(try TextFileAccess.read(file), other)
        XCTAssertThrowsError(try TextFileAccess.write(edit, to: folder.appendingPathComponent("missing/untouched.txt")))
        XCTAssertEqual(try TextFileAccess.read(file), other)
        try TextFileAccess.write(edit, to: file, replacing: base, force: true)
        XCTAssertEqual(try TextFileAccess.read(file), edit)
    }

    func testFindModesAndRegexCaptureReplacement() throws {
        var query = SearchQuery()
        query.pattern = "cat"
        query.wholeWord = true
        XCTAssertEqual(try query.matches(in: "cat Cat category écat 猫cat cat_").count, 2)
        query.matchCase = true
        XCTAssertEqual(try query.matches(in: "cat Cat").count, 1)
        XCTAssertEqual(try query.replacingAll(in: "cat Cat", with: "$1").text, "$1 Cat")
        query.isRegex = true
        query.pattern = #"id-(\d+)"#
        let replaced = try query.replacingAll(in: "id-42\nid-72", with: "item[$1]")
        XCTAssertEqual(replaced.text, "item[42]\nitem[72]")
        XCTAssertEqual(replaced.count, 2)
        query.pattern = "("
        XCTAssertThrowsError(try query.matches(in: "anything"))
        query.pattern = ""
        XCTAssertEqual(try query.replacingAll(in: "anything", with: "changed").text, "anything")
    }

    func testLineIndexIncrementalChangesMatchFreshIndex() {
        var source = "one\n💻two\nthree\nfour\n" as NSString
        var index = LineIndex(source as String)
        let edits: [(NSRange, String)] = [
            (NSRange(location: 3, length: 1), ""),
            (NSRange(location: 0, length: 0), "\n\n"),
            (NSRange(location: 5, length: 0), "x\n"),
            (NSRange(location: 0, length: 4), "a"),
            (NSRange(location: 5, length: 3), "\n"),
        ]
        for (range, value) in edits {
            source = source.replacingCharacters(in: range, with: value) as NSString
            index.update(in: source, editedRange: NSRange(location: range.location, length: value.utf16.count),
                         changeInLength: value.utf16.count - range.length)
            XCTAssertEqual(index.starts, LineIndex(source as String).starts)
        }
    }

    func testCleanupActsOnTouchedLinesAndPreservesFinalNewline() {
        let text = "z  \nb  \na \n"
        XCTAssertEqual(Cleanup.trim.edit(in: text, selection: NSRange(location: 4, length: 4)).replacement, "b\n")
        XCTAssertEqual(Cleanup.sort.edit(in: "z\nb\na", selection: NSRange()).replacement, "a\nb\nz")
        XCTAssertEqual(Cleanup.sort.edit(in: "z\nb\na\n", selection: NSRange()).replacement, "a\nb\nz\n")
        XCTAssertEqual(Cleanup.uppercase.edit(in: "éx", selection: NSRange(location: 0, length: 1)).replacement, "É")
    }

    func testSyntaxDetectionAndHighlightingForEveryLanguage() {
        let fixtures: [(String, String, SyntaxLanguage, SyntaxLanguage.TokenKind)] = [
            ("swift", "let value = 1", .swift, .keyword),
            ("js", "const value = 'ok'", .javascript, .quoted),
            ("ts", "interface Example {}", .typescript, .keyword),
            ("json", "{\"value\": 1}", .json, .property),
            ("html", "<p class=\"x\">Text</p>", .html, .property),
            ("css", "p { color: #ffeecc; }", .css, .property),
            ("md", "# Title", .markdown, .heading)
        ]
        for (ext, sample, language, kind) in fixtures {
            XCTAssertEqual(SyntaxLanguage.detect(URL(fileURLWithPath: "/tmp/example.\(ext)")), language)
            XCTAssertTrue(language.tokens(in: sample).contains(where: { $0.kind == kind }), ext)
        }
        XCTAssertTrue(SyntaxLanguage.plain.tokens(in: "# Header").isEmpty)
    }

    func testMarkdownRendersBlocksLinksAndLocalImagesOffline() throws {
        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1i0AAAAASUVORK5CYII=")!
        try png.write(to: folder.appendingPathComponent("dot image.png"))
        let source = """
        # Title

        **Bold** and *italic* with [site](https://example.com).

        - List item

        > Quoted

        | Key | Value |
        | --- | --- |
        | a | b |

        ```swift
        let x = "<tag>"
        ```

        ![Local](dot%20image.png)

        ![Remote](https://example.com/dot.png)
        """
        let result = MarkdownPreview.html(for: source, fileURL: folder.appendingPathComponent("page.md"))
        for fragment in ["<h1>Title</h1>", "<strong>Bold</strong>", "<em>italic</em>", "<ul>", "<blockquote>",
                         "<table>", "<pre><code>", "&lt;tag&gt;", "href=\"https://example.com\"", "data:image/png;base64,"] {
            XCTAssertTrue(result.contains(fragment), "Missing \(fragment) in \(result)")
        }
        XCTAssertFalse(result.contains("https://example.com/dot.png"))
        XCTAssertTrue(result.contains("img-src data:"))
    }
}

func fixtureDirectory() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Textley-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}
