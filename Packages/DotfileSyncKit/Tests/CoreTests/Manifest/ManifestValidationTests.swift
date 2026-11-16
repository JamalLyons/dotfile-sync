import Core
import Testing

/// Ports of crates/dotfilesync-core/tests/manifest_validation_tests.rs.
struct ManifestValidationTests {
    // Ports Rust test: manifest_validation_tests::test_valid_manifest_passes_validation
    @Test func validManifestPassesValidation() {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.packageManagers = PackageManagersSection(
            homebrew: HomebrewSection(formulae: ["git", "fish"], casks: ["ghostty"])
        )
        manifest.files = [
            TrackedFile(
                source: "fish/config.fish",
                target: "~/.config/fish/config.fish",
                description: "Fish config"
            ),
            TrackedFile(source: "zed/settings.json", target: "~/.config/zed/settings.json"),
        ]
        #expect(validateManifest(manifest).isEmpty)
    }

    // Ports Rust test: manifest_validation_tests::test_unsupported_schema_version
    @Test(arguments: [UInt32(0), 2, 999])
    func unsupportedSchemaVersion(version: UInt32) {
        let errors = validateManifest(Manifest(schemaVersion: version))
        #expect(
            errors.contains(.unsupportedSchemaVersion(version: version, expected: CURRENT_SCHEMA_VERSION)),
            "schema version \(version) should be rejected"
        )
    }

    // Ports Rust test: manifest_validation_tests::test_empty_source_and_target
    @Test func emptySourceAndTarget() {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.files = [
            TrackedFile(source: "   ", target: "~/.config/foo"),
            TrackedFile(source: "foo", target: ""),
        ]
        let errors = validateManifest(manifest)
        #expect(errors.count == 2)
        #expect(errors.contains { if case .emptySourcePath = $0 { true } else { false } })
        #expect(errors.contains { if case .emptyTargetPath = $0 { true } else { false } })
    }

    // Ports Rust test: manifest_validation_tests::test_duplicate_target_rejected
    @Test func duplicateTargetRejected() {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.files = [
            TrackedFile(source: "foo", target: "~/.config/common.conf"),
            TrackedFile(source: "bar", target: "~/.config/common.conf"),
        ]
        let errors = validateManifest(manifest)
        #expect(errors.contains { if case .duplicateTargetPath = $0 { true } else { false } })
    }

    // Ports Rust test: manifest_validation_tests::test_directory_traversal_rejected
    @Test func directoryTraversalRejected() {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.files = [TrackedFile(source: "../secrets/token.txt", target: "~/.config/token")]
        let errors = validateManifest(manifest)
        #expect(errors.contains { if case .illegalPathTraversal = $0 { true } else { false } })
    }

    // Ports Rust test: manifest_validation_tests::test_absolute_source_path_rejected
    @Test func absoluteSourcePathRejected() {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.files = [TrackedFile(source: "/etc/passwd", target: "~/.config/evil")]
        let errors = validateManifest(manifest)
        #expect(errors.contains { if case .absoluteSourcePath = $0 { true } else { false } })
    }

    // Ports Rust test: manifest_validation_tests::test_sensitive_credential_paths_rejected
    @Test(arguments: [
        ("ssh/key", "~/.ssh/id_rsa"),
        ("ssh/id_ed25519", "~/.config/key"),
        ("aws", "~/.aws/credentials"),
        ("gpg", "~/.gnupg/secring.gpg"),
    ])
    func sensitiveCredentialPathsRejected(source: String, target: String) {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.files = [TrackedFile(source: source, target: target)]
        let errors = validateManifest(manifest)
        #expect(
            errors.contains { if case .sensitiveCredentialPath = $0 { true } else { false } },
            "Expected sensitive credential error for target '\(target)'"
        )
    }

    // Ports Rust test: manifest_validation_tests::test_invalid_exclusion_glob_pattern
    @Test func invalidExclusionGlobPattern() {
        let toml = """
            schema_version = 1

            [exclusions]
            patterns = ["[-a-z"]
            """
        #expect {
            _ = try parseManifest(toml)
        } throws: { error in
            "\(error)".contains("Invalid exclusion pattern")
        }
    }

    // Not a Rust port: pins the exact glob crate message for the pattern above (A3).
    @Test func invalidExclusionGlobPatternMessage() {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.exclusions.patterns = ["[-a-z", "a**b", "***", "*.ok", "[!x]", "**/a"]
        #expect(validateManifest(manifest).map(\.description) == [
            "Invalid exclusion pattern '[-a-z': Pattern syntax error near position 0: invalid range pattern",
            "Invalid exclusion pattern 'a**b': Pattern syntax error near position 0: recursive wildcards must form a single path component",
            "Invalid exclusion pattern '***': Pattern syntax error near position 2: wildcards are either regular `*` or recursive `**`",
        ])
    }
}
