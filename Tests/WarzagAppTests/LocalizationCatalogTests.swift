import Foundation
import Testing
@testable import WarzagApp

/// App/Localizable.xcstrings and the string table in Sources/WarzagApp/Model/Strings.swift must agree (the catalog is
/// generated from it by App/strings-catalog.py), and the views must show only strings from the table.
struct LocalizationCatalogTests {
    static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let sources = repository.appending(path: "Sources/WarzagApp", directoryHint: .isDirectory)

    /// key -> English text with every interpolation as %@ (or %n$@ when there are several).
    static func table() throws -> [String: String] {
        let source = try String(contentsOf: sources.appending(path: "Model/Strings.swift"), encoding: .utf8)
        let entry = try NSRegularExpression(pattern: #"String\(localized:\s*"([^"]+)",\s*defaultValue:\s*"((?:[^"\\]|\\.)*)""#)
        let interpolation = try NSRegularExpression(pattern: #"\\\((?:[^()]|\([^()]*\))*\)"#)
        var table: [String: String] = [:]
        for match in entry.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let key = String(source[Range(match.range(at: 1), in: source)!])
            var value = String(source[Range(match.range(at: 2), in: source)!])
            let holes = interpolation.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for (index, hole) in holes.enumerated().reversed() {
                let placeholder = holes.count == 1 ? "%@" : "%\(index + 1)$@"
                value.replaceSubrange(Range(hole.range, in: value)!, with: placeholder)
            }
            table[key] = value.replacingOccurrences(of: #"\""#, with: "\"")
        }
        return table
    }

    static func catalog() throws -> [String: String] {
        let data = try Data(contentsOf: repository.appending(path: "App/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "en")
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        return strings.compactMapValues { entry in
            ((entry["localizations"] as? [String: Any])?["en"] as? [String: Any]).flatMap {
                ($0["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
    }

    @Test func theCatalogHasExactlyTheTablesStringsInEnglish() throws {
        let table = try Self.table()
        let catalog = try Self.catalog()
        #expect(table.count > 200)
        #expect(Set(table.keys).subtracting(catalog.keys).sorted() == [], "missing from the catalog")
        #expect(Set(catalog.keys).subtracting(table.keys).sorted() == [], "stale in the catalog")
        for (key, value) in table {
            #expect(catalog[key] == value, "\(key)")
        }
    }

    @Test func viewsShowNoStringOutsideTheTable() throws {
        let literal = try NSRegularExpression(pattern:
            #"\b(Text|Button|Label|Toggle|Section|Picker|LabeledContent|Window|ProgressView)\(\s*"|\.(accessibilityLabel|accessibilityHint|help|navigationTitle)\(\s*""#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.hasSuffix("Strings.swift") } ?? []
        #expect(files.count > 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                if literal.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders == [])
    }

    @Test func theTableFormatsItsValuesWithoutTheCatalog() {
        // Outside an app bundle (swift test) the English default is used, with the values in place.
        #expect(L10n.bytesOf("23.4 GB", "55.7 GB") == "23.4 GB of 55.7 GB")
        #expect(L10n.checkStorageFree("395.11 GB") == "395.11 GB free")
        #expect(L10n.trackTitle(.engine) == "Engine")
        #expect(L10n.cardTitle(.acceptEULA) == "Accept Digital Extremes' license")
        #expect(L10n.eulaLiveBody.contains("in the window that just opened"))
    }
}
