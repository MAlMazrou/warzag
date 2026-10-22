import Foundation
import Testing
@testable import SteamHostKit

@Suite struct VDFTests {
    @Test func registryShapedFileWithCaseInsensitivePaths() throws {
        let text = """
            "Registry"
            {
            \t"HKLM"
            \t{
            \t\t"Software"
            \t\t{
            \t\t\t"Valve"
            \t\t\t{
            \t\t\t\t"Steam"
            \t\t\t\t{
            \t\t\t\t\t"SteamPID"\t\t"4242"
            \t\t\t\t\t"ClientLauncherType"\t\t"0"
            \t\t\t\t}
            \t\t\t}
            \t\t}
            \t}
            }
            """
        let root = try VDF.parse(text)
        #expect(root.string(atPath: ["Registry", "HKLM", "Software", "Valve", "Steam", "SteamPID"]) == "4242")
        #expect(root.string(atPath: ["registry", "hklm", "SOFTWARE", "valve", "steam", "steampid"]) == "4242")
        #expect(root.string(atPath: ["Registry", "HKLM", "Software", "Valve", "Steam", "Missing"]) == nil)
        #expect(root.string(atPath: ["Registry", "HKLM"]) == nil)
        #expect(root.value(atPath: ["Registry", "HKLM"])?.objectValue?.entries.count == 1)
    }

    @Test func escapesInKeysAndValues() throws {
        let root = try VDF.parse(#""path" "C:\\Program Files (x86)\\Steam" "say" "he said \"hi\"" "lines" "a\nb\tc" "a\\\"k" "x""#)
        #expect(root["path"]?.stringValue == #"C:\Program Files (x86)\Steam"#)
        #expect(root["say"]?.stringValue == #"he said "hi""#)
        #expect(root["lines"]?.stringValue == "a\nb\tc")
        #expect(root[#"a\"k"#]?.stringValue == "x")
    }

    @Test func unknownEscapesAndUnescapedWindowsPathsSurvive() throws {
        let root = try VDF.parse(#""install" "D:\Games\Steam" "trailing" "C:\\""#)
        #expect(root["install"]?.stringValue == #"D:\Games\Steam"#)
        #expect(root["trailing"]?.stringValue == #"C:\"#)
    }

    @Test func commentsAreSkippedButNotInsideStrings() throws {
        let root = try VDF.parse("""
            // leading comment
            "root" // after a key
            {
                "url" "https://example.com/a//b" // after a value
                // "commented" "out"
            }
            """)
        #expect(root["root"]?["url"]?.stringValue == "https://example.com/a//b")
        #expect(root["root"]?["commented"] == nil)
    }

    @Test func bareTokensAndTightBraces() throws {
        let root = try VDF.parse(#"root{key value "quoted"{"inner""1"}empty""}"#)
        let block = try #require(root["root"]?.objectValue)
        #expect(block["key"]?.stringValue == "value")
        #expect(block["quoted"]?["inner"]?.stringValue == "1")
        #expect(block["empty"]?.stringValue == "")
    }

    @Test func conditionalsAreAcceptedAndIgnored() throws {
        let root = try VDF.parse("""
            "settings"
            {
                "font" "Tahoma" [$WIN32]
                "font" "Helvetica" [$OSX]
                "size" [!$X360] "12"
            }
            """)
        let settings = try #require(root["settings"]?.objectValue)
        #expect(settings["FONT"]?.stringValue == "Tahoma")
        #expect(settings.entries.map(\.key) == ["font", "font", "size"])
        #expect(settings["size"]?.stringValue == "12")
    }

    @Test func byteOrderMarkCRLFAndUnicode() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("\"osx\"\r\n{\r\n\t\"version\"\t\t\"1788652215\"\r\n\t\"name\"\t\"مرحبا ✓\"\r\n}\r\n".utf8))
        let root = try VDF.parse(data)
        #expect(root["osx"]?["version"]?.stringValue == "1788652215")
        #expect(root["osx"]?["name"]?.stringValue == "مرحبا ✓")
    }

    @Test func multiLineStringsAndEmptyFiles() throws {
        #expect(try VDF.parse("\"note\" \"line one\nline two\"")["note"]?.stringValue == "line one\nline two")
        #expect(try VDF.parse("").entries.isEmpty)
        #expect(try VDF.parse("  // only a comment\n").entries.isEmpty)
    }

    @Test func controlBytesSeparateTokens() throws {
        let root = try VDF.parse(Data("\u{01}key\u{02}value".utf8))
        #expect(root["key"]?.stringValue == "value")
    }

    @Test(arguments: [
        ("\"open\" \"never closed", "unterminated string", 1, 8),
        ("\"a\"\n{\n\"b\" \"c\"\n", "missing '}' at end of file", 4, 1),
        ("}", "unexpected '}'", 1, 1),
        ("\"lonely\"", "key \"lonely\" has no value", 1, 9),
        ("\"a\" { \"b\" }", "key \"b\" has no value", 1, 11),
        ("{ \"a\" \"b\" }", "block without a key", 1, 1),
    ])
    func malformedInputIsReportedWithAPosition(_ text: String, _ message: String, _ line: Int, _ column: Int) {
        #expect(throws: VDFParseError(message: message, line: line, column: column)) { try VDF.parse(text) }
    }

    @Test func absurdNestingIsRejected() {
        let text = String(repeating: "a{", count: 300) + String(repeating: "}", count: 300)
        #expect(throws: VDFParseError.self) { try VDF.parse(text) }
    }
}
