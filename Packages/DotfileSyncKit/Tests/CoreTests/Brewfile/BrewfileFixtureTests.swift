import Foundation
import Testing

@testable import Core

/// Fixture-backed checks mirroring what the Rust CLI tests require of the parser, plus
/// exact message/JSON parity checks derived from parser.rs.
@Suite("Brewfile parser (fixtures and parity)")
struct BrewfileFixtureTests {
    // Rust: cli_tests.rs::test_cli_import_brewfile_standard ("Imported 4 formulae and 2 casks statically.")
    @Test func standardFixture() throws {
        let content = try String(contentsOf: TestPaths.fixture("Brewfile.standard"), encoding: .utf8)
        let res = parseBrewfile(content)
        #expect(res.formulae == ["bat", "fish", "git", "ripgrep"])
        #expect(res.casks == ["ghostty", "zed"])
        #expect(res.unsupportedConstructs.isEmpty)
        #expect(
            res.diagnostics == [
                .warning(
                    #"Line 6: brew options on 'brew "bat", args: ["--HEAD"]' are not tracked by dotfilesync manifest"#
                ),
                .info("Successfully parsed Brewfile: 4 formulae, 2 casks"),
            ]
        )
    }

    // Rust: cli_tests.rs::test_cli_import_brewfile_dynamic_json (construct types dynamic_ruby and tap)
    @Test func dynamicFixture() throws {
        let content = try String(contentsOf: TestPaths.fixture("Brewfile.dynamic"), encoding: .utf8)
        let res = parseBrewfile(content)
        #expect(res.formulae == ["git"])
        #expect(res.casks.isEmpty)
        #expect(
            res.unsupportedConstructs.map(\.constructType) == [
                "tap", "dynamic_ruby", "dynamic_ruby", "dynamic_ruby", "dynamic_ruby", "mas",
                "bundle_extension", "dynamic_ruby", "dynamic_ruby", "dynamic_ruby",
            ]
        )
        #expect(
            res.unsupportedConstructs.map(\.lineNumber) == [3, 7, 8, 9, 10, 12, 13, 15, 16, 17]
        )
        #expect(res.unsupportedConstructs[2].rawLine == #"  cask "docker""#)
        #expect(
            res.unsupportedConstructs[2].reason
                == "Package declaration inside unsupported Ruby control-flow block 'if' (opened at line 7) cannot be evaluated statically and will not be imported"
        )
        #expect(
            res.unsupportedConstructs[4].reason
                == "Ruby control-flow block 'if' (opened at line 7) closed with 'end'"
        )
        #expect(
            res.unsupportedConstructs[8].reason
                == "Statement inside unsupported Ruby control-flow block 'def' (opened at line 15)"
        )
        #expect(
            res.diagnostics.last
                == .warning("Parsed Brewfile with 1 formulae, 0 casks, and 10 unsupported/dynamic constructs")
        )
        #expect(
            res.diagnostics.first
                == .warning(
                    #"Line 8: Conditional package declaration 'cask "docker"' inside 'if' block (line 7) will not be imported"#
                )
        )

        let data = try JSONEncoder().encode(res)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""construct_type":"dynamic_ruby""#))
        #expect(json.contains(#""construct_type":"tap""#))
    }

    // Parity: JSON keys match serde snake_case output and round-trip.
    @Test func jsonKeysAndRoundTrip() throws {
        let res = parseBrewfile("tap \"x\"\nbrew \"git\"\n")
        let data = try JSONEncoder().encode(res)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["formulae", "casks", "unsupported_constructs", "diagnostics"])
        let constructs = try #require(object["unsupported_constructs"] as? [[String: Any]])
        #expect(Set(constructs[0].keys) == ["line_number", "raw_line", "construct_type", "reason"])
        #expect(try JSONDecoder().decode(BrewfileParseResult.self, from: data) == res)
    }

    // Parity: unclosed block message, de-duplication, CRLF line endings, malformed reasons.
    @Test func exactMessagesAndEdgeCases() {
        let unclosed = parseBrewfile("if OS.mac?\n  brew \"coreutils\"\n")
        let last = unclosed.unsupportedConstructs.last
        #expect(last?.rawLine == "Unclosed block 'if'")
        #expect(last?.lineNumber == 1)
        #expect(
            last?.reason
                == "Unclosed Ruby control-flow block 'if' opened at line 1; scope cannot be safely established"
        )

        let dup = parseBrewfile("brew \"git\"\r\nbrew \"git\"\r\nbrew \"Zsh\"\r\nbrew \"awk\"\r\n")
        #expect(dup.formulae == ["Zsh", "awk", "git"])
        #expect(dup.unsupportedConstructs.isEmpty)

        let malformed = parseBrewfile("brew unquoted\ncask \"\"\nbrew \"a#{b}\"\nend\n")
        #expect(
            malformed.unsupportedConstructs.map(\.reason) == [
                "Expected opening quote for package name: 'unquoted'",
                "Package name inside quotes is empty",
                "String interpolation in package name is not supported",
                "Unexpected 'end' without matching block opening; scope cannot be safely established",
            ]
        )
        #expect(
            malformed.diagnostics.first
                == .warning(
                    "Line 1: Conditional or unsupported package declaration 'brew unquoted' will not be imported: Expected opening quote for package name: 'unquoted'"
                )
        )
    }
}
