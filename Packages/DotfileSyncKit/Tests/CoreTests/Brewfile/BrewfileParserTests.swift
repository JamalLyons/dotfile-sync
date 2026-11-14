import Foundation
import Testing

@testable import Core

/// Ports of crates/dotfilesync-core/tests/brewfile_tests.rs.
@Suite("Brewfile parser (integration tests)")
struct BrewfileIntegrationTests {
    // Rust: brewfile_tests.rs::test_standard_brewfile_parsing
    @Test func standardBrewfileParsing() {
        let content = """

            # Core CLI
            brew "fish"
            brew 'git'
            brew "ripgrep"

            # GUI casks
            cask "ghostty"
            cask 'zed'

            """
        let res = parseBrewfile(content)
        #expect(res.formulae == ["fish", "git", "ripgrep"])
        #expect(res.casks == ["ghostty", "zed"])
        #expect(res.unsupportedConstructs.isEmpty)
    }

    // Rust: brewfile_tests.rs::test_ordinary_names_with_substrings_import_correctly
    @Test func ordinaryNamesWithSubstringsImportCorrectly() {
        let content = """

            brew "calendar"
            brew "blender"
            cask "rectangle" # system utility

            """
        let res = parseBrewfile(content)
        #expect(res.formulae == ["blender", "calendar"])
        #expect(res.casks == ["rectangle"])
        #expect(res.unsupportedConstructs.isEmpty)
    }

    // Rust: brewfile_tests.rs::test_unsupported_trailing_expression_is_flagged
    @Test func unsupportedTrailingExpressionIsFlagged() throws {
        let res = parseBrewfile(#"brew "git" + extra"#)
        #expect(res.formulae.isEmpty)
        try #require(res.unsupportedConstructs.count == 1)
        #expect(res.unsupportedConstructs[0].constructType == "unsupported_expression")
    }

    // Rust: brewfile_tests.rs::test_brew_and_cask_with_options
    @Test func brewAndCaskWithOptions() {
        let content = """

            brew "neovim", args: ["--HEAD"]
            cask "google-chrome", args: { appdir: "/Applications" }

            """
        let res = parseBrewfile(content)
        #expect(res.formulae == ["neovim"])
        #expect(res.casks == ["google-chrome"])
        #expect(res.diagnostics.contains { $0.message.contains("options") })
    }

    // Rust: brewfile_tests.rs::test_unsupported_directives
    @Test func unsupportedDirectives() throws {
        let content = """

            tap "homebrew/cask-fonts"
            mas "Xcode", id: 497799835
            whalebrew "whale"
            vscode "rust-lang.rust-analyzer"

            """
        let res = parseBrewfile(content)
        #expect(res.formulae.isEmpty)
        #expect(res.casks.isEmpty)
        try #require(res.unsupportedConstructs.count == 4)
        #expect(
            res.unsupportedConstructs.map(\.constructType)
                == ["tap", "mas", "bundle_extension", "bundle_extension"]
        )
    }

    // Rust: brewfile_tests.rs::test_dynamic_ruby_constructs
    @Test func dynamicRubyConstructs() {
        let content = """

            if OS.mac?
              brew "coreutils"
            end

            def install_extras
              system "echo hello"
            end

            cask "app_#{ENV['ENV_TYPE']}"

            """
        let res = parseBrewfile(content)
        #expect(res.formulae.isEmpty, "coreutils inside if block must not be imported")
        #expect(res.casks.isEmpty, "interpolated cask must not be imported")
        #expect(res.unsupportedConstructs.count >= 4)
        for u in res.unsupportedConstructs {
            #expect(u.constructType == "dynamic_ruby")
        }
    }

    // Rust: brewfile_tests.rs::test_conditional_block_packages_not_imported_and_warned
    @Test func conditionalBlockPackagesNotImportedAndWarned() {
        let content = """

            brew "git"

            if OS.mac?
              brew "coreutils"
              cask "docker"
            end

            unless OS.linux?
              brew "htop"
            end

            """
        let res = parseBrewfile(content)
        #expect(res.formulae == ["git"])
        #expect(res.casks.isEmpty)
        #expect(!res.formulae.contains("coreutils"))
        #expect(!res.formulae.contains("htop"))
        #expect(!res.casks.contains("docker"))

        for name in ["coreutils", "docker", "htop"] {
            #expect(res.diagnostics.contains { $0.message.contains(name) })
            #expect(res.unsupportedConstructs.contains { $0.rawLine.contains(name) })
        }
    }

    // Rust: brewfile_tests.rs::test_trailing_conditional_modifiers_not_imported_and_warned
    @Test func trailingConditionalModifiersNotImportedAndWarned() {
        let content = """

            brew "wget", args: ["with-iri"] if OS.mac?
            cask "docker" unless OS.linux?
            brew "curl" if condition

            """
        let res = parseBrewfile(content)
        #expect(res.formulae.isEmpty, "Conditional brew declarations must not be imported")
        #expect(res.casks.isEmpty, "Conditional cask declarations must not be imported")

        for name in ["wget", "docker", "curl"] {
            #expect(res.diagnostics.contains { $0.message.contains(name) })
        }

        #expect(res.unsupportedConstructs.count == 3)
        for u in res.unsupportedConstructs {
            #expect(u.constructType == "dynamic_ruby")
            #expect(u.reason.contains("conditional"))
        }
    }

    // Rust: brewfile_tests.rs::test_nested_ruby_blocks_handled_conservatively
    @Test func nestedRubyBlocksHandledConservatively() {
        let content = """

            if OS.mac?
              if Hardware::CPU.arm?
                brew "arm-tool"
              end
              brew "intel-tool"
            end

            """
        let res = parseBrewfile(content)
        #expect(res.formulae.isEmpty)
        #expect(!res.formulae.contains("arm-tool"))
        #expect(!res.formulae.contains("intel-tool"))
        #expect(res.diagnostics.contains { $0.message.contains("arm-tool") })
        #expect(res.diagnostics.contains { $0.message.contains("intel-tool") })
    }

    // Rust: brewfile_tests.rs::test_malformed_syntax
    @Test func malformedSyntax() throws {
        let content = """

            brew unquoted_package
            cask "unterminated_quote

            """
        let res = parseBrewfile(content)
        try #require(res.unsupportedConstructs.count == 2)
        #expect(res.unsupportedConstructs[0].constructType == "malformed_syntax")
        #expect(res.unsupportedConstructs[1].constructType == "malformed_syntax")
    }

    // Rust: brewfile_tests.rs::test_original_brewfile_preserved
    @Test func originalBrewfilePreserved() throws {
        let brewfileURL = TestPaths.repoRoot.appendingPathComponent("Brewfile")
        let original = try String(contentsOf: brewfileURL, encoding: .utf8)
        let res = parseBrewfile(original)
        #expect(!res.formulae.isEmpty)
        #expect(!res.casks.isEmpty)

        let after = try String(contentsOf: brewfileURL, encoding: .utf8)
        #expect(original == after, "Brewfile must remain identical")
    }

    // Rust: brewfile_tests.rs::test_beginner_variable_does_not_suppress_following_brew_declaration
    @Test func beginnerVariableDoesNotSuppressFollowingBrewDeclaration() throws {
        let content = """

            beginner = true
            brew "git"

            """
        let res = parseBrewfile(content)
        #expect(res.formulae == ["git"])
        try #require(res.unsupportedConstructs.count == 1)
        #expect(res.unsupportedConstructs[0].constructType == "unrecognized")
    }
}
