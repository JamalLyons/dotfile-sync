import Foundation
import System
import Testing

@testable import Core

@Suite("JSON output")
struct JSONOutputTests {
    private struct Sample: Encodable {
        var zeta = "z/y"
        var alpha: [Int] = []
        var nested: [String: Int] = [:]
        var optional: String?
        var list = [true, false]

        enum CodingKeys: String, CodingKey { case zeta, alpha, nested, optional, list }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(zeta, forKey: .zeta)
            try c.encode(alpha, forKey: .alpha)
            try c.encode(nested, forKey: .nested)
            try c.encodeIfPresent(optional, forKey: .optional)
            try c.encode(list, forKey: .list)
        }
    }

    @Test func prettyMatchesSerdeLayout() throws {
        let expected = """
            {
              "zeta": "z/y",
              "alpha": [],
              "nested": {},
              "list": [
                true,
                false
              ]
            }
            """
        #expect(try jsonStringPretty(Sample()) == expected)
        #expect(try jsonStringCompact(Sample()) == #"{"zeta":"z/y","alpha":[],"nested":{},"list":[true,false]}"#)
    }

    @Test func escapesLikeSerde() throws {
        #expect(try jsonStringCompact("a\"b\\c\n\t\u{01}\u{7F}é/") == #""a\"b\\c\n\t\u0001"# + "\u{7F}é/\"")
    }

    @Test func numbersAndNull() throws {
        #expect(try jsonStringCompact([UInt64.max]) == "[18446744073709551615]")
        #expect(try jsonStringCompact([Int64.min]) == "[-9223372036854775808]")
        #expect(try jsonStringCompact([String?.none]) == "[null]")
        #expect(throws: JSONOutputError.nonFiniteNumber) { try jsonStringCompact([Double.nan]) }
    }

    @Test func observedConfigFileOmitsNilFieldsInDeclarationOrder() throws {
        let observed = ObservedConfigFile(sourcePath: "/r/s", targetPath: "/h/t", state: .symlinkToSource,
                                          sourceHash: "aa", targetHash: "aa", isSymlink: true,
                                          symlinkTarget: "/r/s", diagnostic: "d")
        #expect(try jsonStringCompact(observed) == #"{"source_path":"/r/s","target_path":"/h/t","#
            + #""state":"symlink_to_source","source_hash":"aa","target_hash":"aa","is_symlink":true,"#
            + #""symlink_target":"/r/s","diagnostic":"d"}"#)
        let decoded = try JSONDecoder().decode(ObservedConfigFile.self, from: Data(try jsonStringCompact(observed).utf8))
        #expect(decoded == observed)
    }

    @Test func statusReportRoundTrips() throws {
        let report = StatusReport(
            schemaVersion: 1, homebrewAvailable: true, brewVersion: "Homebrew 4.3.0",
            packageDifferences: [PackageDifference(name: "git", kind: .formula, classification: .matching,
                                                   desired: true, installed: true, observedVersion: "2")],
            configDifferences: [ConfigDifference(source: "s", target: "t", classification: .unknown,
                                                 state: .sourceOutsideRoot)],
            diagnostics: [.warning("w")])
        let text = try jsonStringPretty(report)
        let decoded = try JSONDecoder().decode(StatusReport.self, from: Data(text.utf8))
        #expect(decoded == report)
    }

    @Test func scanReportKeyOrder() throws {
        let report = ScanReport(homebrew: BrewDiscoveryResult(), configs: [], diagnostics: [])
        #expect(try jsonStringCompact(report) == #"{"homebrew":{"available":false,"packages_enumerated":false,"#
            + #""formulae":[],"casks":[],"diagnostics":[]},"configs":[],"diagnostics":[]}"#)
        let decoded = try JSONDecoder().decode(ScanReport.self, from: Data(try jsonStringCompact(report).utf8))
        #expect(decoded == report)
    }
}
