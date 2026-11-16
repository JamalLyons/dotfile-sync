import Core
import Testing

/// Ports of crates/dotfilesync-core/tests/profile_tests.rs.
struct ProfileTests {
    private func resolve(_ toml: String, _ selection: ProfileSelection, _ hostname: String) throws -> ResolvedManifest {
        let manifest = try parseManifest(toml)
        return try resolveProfile(manifest, selection: selection, hostname: hostname, os: .macos)
    }

    // Ports Rust test: profile_tests::base_only_ignores_profiles
    @Test func baseOnlyIgnoresProfiles() throws {
        let toml = """
            schema_version = 1

            [package_managers.homebrew]
            formulae = ["git", "fish"]
            casks = ["zed"]

            [[files]]
            source = "fish/config.fish"
            target = "~/.config/fish/config.fish"

            [profiles.work.package_managers.homebrew]
            formulae = ["awscli"]
            """
        let resolved = try resolve(toml, .baseOnly, "work-mac")
        #expect(resolved.profile == nil)
        #expect(resolved.homebrew.formulae == ["fish", "git"])
        #expect(resolved.homebrew.casks == ["zed"])
        #expect(resolved.files.count == 1)
    }

    // Ports Rust test: profile_tests::overlay_adds_packages
    @Test func overlayAddsPackages() throws {
        let toml = """
            schema_version = 1

            [package_managers.homebrew]
            formulae = ["git"]
            casks = ["zed"]

            [profiles.work.package_managers.homebrew]
            formulae = ["awscli", "git"]
            casks = ["slack"]
            """
        let resolved = try resolve(toml, .explicit("work"), "host")
        #expect(resolved.profile == "work")
        #expect(resolved.homebrew.formulae == ["awscli", "git"])
        #expect(resolved.homebrew.casks == ["slack", "zed"])
    }

    // Ports Rust test: profile_tests::exclude_removes_package_from_earlier_layer
    @Test func excludeRemovesPackageFromEarlierLayer() throws {
        let toml = """
            schema_version = 1

            [package_managers.homebrew]
            formulae = ["git", "minecraft"]
            casks = ["steam", "zed"]

            [profiles.work.package_managers.homebrew]
            exclude_formulae = ["minecraft"]
            exclude_casks = ["steam"]
            """
        let resolved = try resolve(toml, .explicit("work"), "host")
        #expect(resolved.homebrew.formulae == ["git"])
        #expect(resolved.homebrew.casks == ["zed"])
    }

    // Ports Rust test: profile_tests::later_layer_readds_excluded_package
    @Test func laterLayerReaddsExcludedPackage() throws {
        let toml = """
            schema_version = 1

            [package_managers.homebrew]
            formulae = ["minecraft"]

            [profiles.personal.package_managers.homebrew]
            exclude_formulae = ["minecraft"]

            [profiles.work]
            extends = ["personal"]

            [profiles.work.package_managers.homebrew]
            formulae = ["minecraft", "awscli"]
            """
        let resolved = try resolve(toml, .explicit("work"), "host")
        #expect(resolved.homebrew.formulae == ["awscli", "minecraft"])
    }

    // Ports Rust test: profile_tests::conflicting_file_target_later_layer_wins
    @Test func conflictingFileTargetLaterLayerWins() throws {
        let toml = """
            schema_version = 1

            [[files]]
            source = "base/config.fish"
            target = "~/.config/fish/config.fish"
            mode = "copy"

            [[profiles.work.files]]
            source = "work/config.fish"
            target = "~/.config/fish/config.fish"
            mode = "symlink"

            [profiles.work]
            exclude_files = []
            """
        let resolved = try resolve(toml, .explicit("work"), "host")
        #expect(resolved.files.count == 1)
        #expect(resolved.files.first?.source == "work/config.fish")
        #expect(resolved.files.first?.mode == .symlink)
    }

    // Ports Rust test: profile_tests::exclude_files_removes_by_target
    @Test func excludeFilesRemovesByTarget() throws {
        let toml = """
            schema_version = 1

            [[files]]
            source = "zed/settings.json"
            target = "~/.config/zed/settings.json"

            [[files]]
            source = "fish/config.fish"
            target = "~/.config/fish/config.fish"

            [profiles.work]
            exclude_files = ["~/.config/zed/settings.json"]
            """
        let resolved = try resolve(toml, .explicit("work"), "host")
        #expect(resolved.files.count == 1)
        #expect(resolved.files.first?.source == "fish/config.fish")
    }

    // Ports Rust test: profile_tests::extends_chain_is_depth_first_and_cycle_errors
    @Test func extendsChainIsDepthFirstAndCycleErrors() throws {
        let toml = """
            schema_version = 1

            [package_managers.homebrew]
            formulae = ["git"]

            [profiles.base_extra.package_managers.homebrew]
            formulae = ["ripgrep"]

            [profiles.work]
            extends = ["base_extra"]

            [profiles.work.package_managers.homebrew]
            formulae = ["awscli"]
            """
        let resolved = try resolve(toml, .explicit("work"), "host")
        #expect(resolved.homebrew.formulae == ["awscli", "git", "ripgrep"])

        let cycle = """
            schema_version = 1

            [profiles.a]
            extends = ["b"]

            [profiles.b]
            extends = ["a"]
            """
        let error = #expect(throws: ManifestError.self) { _ = try parseManifest(cycle) }
        guard case .validation = error else {
            Issue.record("expected validation error, got \(String(describing: error))")
            return
        }
        #expect(error?.description.contains("cycle") == true)
        // Rust message is "Profile cycle detected: a -> b -> a".
        #expect(error?.description.contains("Profile cycle detected: a -> b -> a") == true)
    }

    // Ports Rust test: profile_tests::hostname_auto_selects_profile_and_strips_local_suffix
    @Test func hostnameAutoSelectsProfileAndStripsLocalSuffix() throws {
        let toml = """
            schema_version = 1

            [select]
            hostnames = { "jamals-mbp" = "personal", "work-mac" = "work" }

            [profiles.personal.package_managers.homebrew]
            casks = ["slack"]

            [profiles.work.package_managers.homebrew]
            casks = ["zoom"]
            """
        let resolved = try resolve(toml, .auto, "Jamals-MBP.local")
        #expect(resolved.profile == "personal")
        #expect(resolved.homebrew.casks == ["slack"])
    }

    // Ports Rust test: profile_tests::default_profile_is_fallback_when_hostname_is_unknown
    @Test func defaultProfileIsFallbackWhenHostnameIsUnknown() throws {
        let toml = """
            schema_version = 1

            [select]
            hostnames = { "jamals-mbp" = "work" }
            default = "personal"

            [profiles.personal.package_managers.homebrew]
            formulae = ["fish"]

            [profiles.work.package_managers.homebrew]
            formulae = ["awscli"]
            """
        let resolved = try resolve(toml, .auto, "other-host")
        #expect(resolved.profile == "personal")
        #expect(resolved.homebrew.formulae == ["fish"])
    }

    // Ports Rust test: profile_tests::unknown_explicit_profile_errors
    @Test func unknownExplicitProfileErrors() throws {
        let toml = """
            schema_version = 1

            [profiles.personal.package_managers.homebrew]
            formulae = ["fish"]
            """
        let manifest = try parseManifest(toml)
        #expect(throws: ManifestError.unknownProfile(name: "nope")) {
            _ = try resolveProfile(manifest, selection: .explicit("nope"), hostname: "host", os: .macos)
        }
    }

    // Ports Rust test: profile_tests::os_mismatch_is_filtered
    @Test func osMismatchIsFiltered() throws {
        let toml = """
            schema_version = 1

            [[files]]
            source = "mac/only.conf"
            target = "~/.config/mac.conf"
            os = "macos"

            [[files]]
            source = "linux/only.conf"
            target = "~/.config/linux.conf"
            os = "linux"

            [profiles.linuxbox]
            os = "linux"

            [profiles.linuxbox.package_managers.homebrew]
            formulae = ["linux-only"]

            [profiles.macbox]
            os = "macos"

            [profiles.macbox.package_managers.homebrew]
            formulae = ["mac-only"]

            [[profiles.macbox.files]]
            source = "mac/extra.conf"
            target = "~/.config/mac-extra.conf"
            os = "linux"
            """
        let mac = try resolve(toml, .explicit("macbox"), "host")
        #expect(mac.homebrew.formulae == ["mac-only"])
        #expect(mac.files.map(\.target) == ["~/.config/mac.conf"])

        let skipped = try resolve(toml, .explicit("linuxbox"), "host")
        #expect(skipped.homebrew.formulae.isEmpty)
        #expect(skipped.files.count == 1)
        #expect(skipped.files.first?.target == "~/.config/mac.conf")
    }

    // Ports Rust test: profile_tests::manifest_without_profiles_resolves_to_base
    @Test func manifestWithoutProfilesResolvesToBase() throws {
        let toml = """
            schema_version = 1

            [package_managers.homebrew]
            formulae = ["git"]

            [[files]]
            source = "fish/config.fish"
            target = "~/.config/fish/config.fish"
            """
        let manifest = try parseManifest(toml)
        #expect(manifest.schemaVersion == 1)
        let resolved = try resolveProfile(manifest, selection: .auto, hostname: "any-host", os: .macos)
        #expect(resolved.profile == nil)
        #expect(resolved.homebrew.formulae == ["git"])
        #expect(resolved.files.count == 1)
    }

    // Ports Rust test: profile_tests::unknown_profile_in_select_is_a_validation_error
    @Test func unknownProfileInSelectIsAValidationError() {
        let toml = """
            schema_version = 1

            [select]
            default = "missing"
            """
        let error = #expect(throws: ManifestError.self) { _ = try parseManifest(toml) }
        guard case .validation = error else {
            Issue.record("expected validation error, got \(String(describing: error))")
            return
        }
        #expect(error?.description.contains("missing") == true)
        #expect(error?.description == """
            Manifest validation failed with 1 errors: - Unknown profile 'missing' referenced from select.default
            """)
    }

    // Not a Rust port: hostname normalization helper.
    @Test func normalizeHostnameStripsLocal() {
        #expect(normalizeHostname("  Work-Mac.LOCAL \n") == "work-mac")
        #expect(normalizeHostname("host") == "host")
        #expect(currentOs() == .macos)
        #expect(!currentHostname().hasSuffix(".local"))
    }
}
