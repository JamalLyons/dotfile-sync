import Testing

@testable import Core

/// Ports of the inline `mod tests` in crates/dotfilesync-core/src/brew/parser.rs.
@Suite("Brewfile parser (inline unit tests)")
struct BrewfileParserInlineTests {
    // Rust: parser.rs::tests::test_parse_clean_brewfile
    @Test func parseCleanBrewfile() {
        let input = """

            # Core CLI
            brew "fish"
            brew "git"
            brew 'gh'

            # GUI apps
            cask "ghostty"
            cask "zed"

            """
        let res = parseBrewfile(input)
        #expect(res.formulae == ["fish", "gh", "git"])
        #expect(res.casks == ["ghostty", "zed"])
        #expect(res.unsupportedConstructs.isEmpty)
    }

    // Rust: parser.rs::tests::test_ordinary_names_with_substrings_do_not_falsely_trigger_dynamic_ruby
    @Test func ordinaryNamesWithSubstringsDoNotFalselyTriggerDynamicRuby() {
        let input = """

            brew "calendar"
            brew "blender"
            cask "rectangle" # system utility

            """
        let res = parseBrewfile(input)
        #expect(res.formulae == ["blender", "calendar"])
        #expect(res.casks == ["rectangle"])
        #expect(res.unsupportedConstructs.isEmpty)
    }

    // Rust: parser.rs::tests::test_unsupported_trailing_expression_is_flagged
    @Test func unsupportedTrailingExpressionIsFlagged() throws {
        let res = parseBrewfile(#"brew "git" + extra"#)
        #expect(res.formulae.isEmpty)
        try #require(res.unsupportedConstructs.count == 1)
        #expect(res.unsupportedConstructs[0].constructType == "unsupported_expression")
    }

    // Rust: parser.rs::tests::test_trailing_conditional_if_and_unless_are_rejected
    @Test func trailingConditionalIfAndUnlessAreRejected() {
        let input = """

            brew "wget", args: ["with-iri"] if OS.mac?
            cask "docker" unless OS.linux?
            brew "curl" if condition

            """
        let res = parseBrewfile(input)
        #expect(res.formulae.isEmpty)
        #expect(res.casks.isEmpty)
        #expect(res.unsupportedConstructs.count == 3)
        for u in res.unsupportedConstructs {
            #expect(u.constructType == "dynamic_ruby")
        }
        #expect(res.diagnostics.contains { $0.message.contains("Conditional") })
    }

    // Rust: parser.rs::tests::test_packages_inside_ruby_control_flow_blocks_not_imported
    @Test func packagesInsideRubyControlFlowBlocksNotImported() {
        let input = """

            brew "git"

            if OS.mac?
              brew "coreutils"
              cask "docker"
            end

            unless OS.linux?
              brew "mac-only-tool"
            end

            """
        let res = parseBrewfile(input)
        #expect(res.formulae == ["git"])
        #expect(res.casks.isEmpty)
        #expect(!res.formulae.contains("coreutils"))
        #expect(!res.formulae.contains("mac-only-tool"))
        #expect(!res.casks.contains("docker"))
        #expect(!res.unsupportedConstructs.isEmpty)
        #expect(res.diagnostics.contains { $0.message.contains("coreutils") })
        #expect(res.diagnostics.contains { $0.message.contains("docker") })
    }

    // Rust: parser.rs::tests::test_nested_ruby_blocks_handled_conservatively
    @Test func nestedRubyBlocksHandledConservatively() {
        let input = """

            if OS.mac?
              if Hardware::CPU.arm?
                brew "arm-pkg"
              end
              brew "intel-pkg"
            end

            """
        let res = parseBrewfile(input)
        #expect(res.formulae.isEmpty)
        #expect(!res.unsupportedConstructs.isEmpty)
    }

    // Rust: parser.rs::tests::test_unclosed_block_at_eof
    @Test func unclosedBlockAtEOF() {
        let input = """

            if OS.mac?
              brew "coreutils"

            """
        let res = parseBrewfile(input)
        #expect(res.formulae.isEmpty)
        #expect(res.unsupportedConstructs.contains { $0.reason.contains("Unclosed") })
    }

    // Rust: parser.rs::tests::test_parse_dynamic_and_unsupported_brewfile
    @Test func parseDynamicAndUnsupportedBrewfile() throws {
        let input = """

            tap "homebrew/cask-fonts"
            brew "git"

            if OS.mac?
              cask "docker"
            end

            mas "Xcode", id: 497799835
            whalebrew "whale"

            """
        let res = parseBrewfile(input)
        #expect(res.formulae == ["git"])
        #expect(res.casks.isEmpty, "cask docker inside if block must not be imported")
        try #require(res.unsupportedConstructs.count == 6)
        #expect(
            res.unsupportedConstructs.map(\.constructType)
                == ["tap", "dynamic_ruby", "dynamic_ruby", "dynamic_ruby", "mas", "bundle_extension"]
        )
    }

    // Rust: parser.rs::tests::test_keyword_prefix_variable_does_not_suppress_following_brew_declaration
    @Test func keywordPrefixVariableDoesNotSuppressFollowingBrewDeclaration() {
        let input = """

            beginner = true
            definitely_true = 1
            format = :json
            brew "git"

            """
        let res = parseBrewfile(input)
        #expect(res.formulae == ["git"])
        for u in res.unsupportedConstructs {
            #expect(u.constructType == "unrecognized")
        }
    }
}
