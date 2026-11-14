import Darwin
import Foundation
import System
import Testing

@testable import Core

/// Port of crates/dotfilesync-core/tests/config_drift_tests.rs.
@Suite("Config drift")
struct ConfigDriftTests {
    private static func write(_ path: String, _ content: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func symlink(_ destination: String, at path: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    private static func inspector(
        _ repo: TempDir, _ home: TempDir,
        exclusions: ExclusionsSection = ExclusionsSection(),
        overrides: [MachineOverride] = []
    ) -> ConfigInspector {
        ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                        exclusions: exclusions, overrides: overrides)
    }

    private static func enumerated() -> BrewDiscoveryResult {
        BrewDiscoveryResult(available: true, packagesEnumerated: true)
    }

    // Ports test_config_matching_and_changed_and_missing
    @Test func configMatchingChangedAndMissing() throws {
        let repo = try TempDir(), home = try TempDir()
        try Self.write("\(repo.path)/config/match.conf", "key=value\n")
        try Self.write("\(repo.path)/config/drift.conf", "setting=default\n")
        try Self.write("\(repo.path)/config/missing.conf", "should=exist\n")
        try Self.write("\(home.path)/.config/match.conf", "key=value\n")
        try Self.write("\(home.path)/.config/drift.conf", "setting=custom_machine_override\n")

        let results = Self.inspector(repo, home).inspectFiles([
            TrackedFile(source: "config/match.conf", target: "~/.config/match.conf"),
            TrackedFile(source: "config/drift.conf", target: "~/.config/drift.conf"),
            TrackedFile(source: "config/missing.conf", target: "~/.config/missing.conf"),
        ])
        #expect(results.count == 3)
        #expect(results[0].state == .matching)
        #expect(results[0].sourceHash == results[0].targetHash)
        #expect(results[1].state == .changed)
        #expect(results[1].sourceHash != results[1].targetHash)
        #expect(try #require(results[1].diagnostic).contains("drift"))
        #expect(results[2].state == .missing)
        #expect(results[2].targetHash == nil)
    }

    // Ports test_machine_local_override_is_preserved_and_never_hashed
    @Test func machineLocalOverrideIsPreservedAndNeverHashed() throws {
        let repo = try TempDir(), home = try TempDir()
        try Self.write("\(home.path)/.config/fish/conf.d/local.fish", "set -gx SECRET_TOKEN 12345\n")
        let inspector = Self.inspector(repo, home, overrides: [
            MachineOverride(target: "~/.config/fish/conf.d/local.fish", description: "Machine local tokens"),
        ])

        let observed = inspector.inspectFile(TrackedFile(
            source: "fish/conf.d/local.fish", target: "~/.config/fish/conf.d/local.fish", machineLocal: true))
        #expect(observed.state == .machineLocal)
        #expect(observed.sourceHash == nil)
        #expect(observed.targetHash == nil)
        #expect(try #require(observed.diagnostic).lowercased().contains("machine-local override"))

        let absent = inspector.inspectFile(TrackedFile(
            source: "fish/conf.d/absent.fish", target: "~/.config/fish/conf.d/absent.fish", machineLocal: true))
        #expect(absent.state == .missing)
        #expect(absent.sourceHash == nil)
        #expect(absent.targetHash == nil)
    }

    // Ports test_explicit_exclusions_path_and_pattern
    @Test func explicitExclusionsPathAndPattern() throws {
        let repo = try TempDir(), home = try TempDir()
        let inspector = Self.inspector(repo, home, exclusions: ExclusionsSection(
            paths: ["~/.config/exact_exclude.conf"], patterns: ["*.backup.*", "*.key"]))
        let results = inspector.inspectFiles([
            TrackedFile(source: "config/exact_exclude.conf", target: "~/.config/exact_exclude.conf"),
            TrackedFile(source: "config/settings.backup.20261108", target: "~/.config/settings.backup.20261108"),
            TrackedFile(source: "config/priv.key", target: "~/.config/priv.key"),
        ])
        for r in results {
            #expect(r.state == .excluded)
            #expect(r.sourceHash == nil)
            #expect(r.targetHash == nil)
        }
    }

    // Ports test_symlink_edge_cases
    @Test func symlinkEdgeCases() throws {
        let repo = try TempDir(), home = try TempDir()
        let source = "\(repo.path)/valid_source.conf"
        try Self.write(source, "symlink source\n")
        let external = "\(repo.path)/other.conf"
        try Self.write(external, "external content\n")
        try FileManager.default.createDirectory(atPath: "\(home.path)/.config", withIntermediateDirectories: true)
        try Self.symlink(source, at: "\(home.path)/.config/to_source.conf")
        try Self.symlink(external, at: "\(home.path)/.config/to_other.conf")
        try Self.symlink("\(repo.path)/nonexistent.conf", at: "\(home.path)/.config/broken.conf")

        let inspector = Self.inspector(repo, home)
        let obs1 = inspector.inspectFile(TrackedFile(source: "valid_source.conf", target: "~/.config/to_source.conf"))
        #expect(obs1.state == .symlinkToSource)
        let obs2 = inspector.inspectFile(TrackedFile(source: "valid_source.conf", target: "~/.config/to_other.conf"))
        #expect(obs2.state == .symlinkExternal)
        let obs3 = inspector.inspectFile(TrackedFile(source: "valid_source.conf", target: "~/.config/broken.conf"))
        #expect(obs3.state == .brokenSymlink)
    }

    // Ports test_source_symlinks_escaping_repo_root_are_rejected
    @Test func sourceSymlinksEscapingRepoRootAreRejected() throws {
        let repo = try TempDir(), outside = try TempDir(), home = try TempDir()
        let outsideFile = "\(outside.path)/secret.conf"
        try Self.write(outsideFile, "OUTSIDE SECRET VALUE\n")
        let outsideDir = "\(outside.path)/external_dir"
        try Self.write("\(outsideDir)/nested.conf", "OUTSIDE NESTED VALUE\n")
        try Self.symlink(outsideFile, at: "\(repo.path)/escape_symlink.conf")
        try Self.symlink(outsideDir, at: "\(repo.path)/escaped_parent")

        let inspector = Self.inspector(repo, home)
        let obs1 = inspector.inspectFile(TrackedFile(source: "escape_symlink.conf", target: "~/.config/target1.conf"))
        #expect(obs1.state == .sourceOutsideRoot)
        #expect(obs1.sourceHash == nil)
        #expect(try #require(obs1.diagnostic).contains("escapes repository root"))

        let obs2 = inspector.inspectFile(TrackedFile(
            source: "escaped_parent/nested.conf", target: "~/.config/target2.conf"))
        #expect(obs2.state == .sourceOutsideRoot)
        #expect(obs2.sourceHash == nil)
        #expect(try #require(obs2.diagnostic).contains("escapes repository root"))
    }

    // Ports test_status_semantics_for_machine_local_and_excluded
    @Test func statusSemanticsForMachineLocalAndExcluded() throws {
        let repo = try TempDir(), home = try TempDir()
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.exclusions.paths = ["~/.config/excluded.conf"]
        manifest.overrides = [MachineOverride(target: "~/.config/local.conf", description: "Machine local")]
        manifest.files = [
            TrackedFile(source: "local.conf", target: "~/.config/local.conf", machineLocal: true),
            TrackedFile(source: "excluded.conf", target: "~/.config/excluded.conf"),
        ]
        try Self.write("\(home.path)/.config/local.conf", "TOKEN=abc\n")

        let configs = Self.inspector(repo, home, exclusions: manifest.exclusions, overrides: manifest.overrides)
            .inspectFiles(manifest.files)
        let report = compareStatus(manifest, brewResult: Self.enumerated(), configs: configs)

        #expect(report.summary.configsMatching == 0)
        #expect(report.summary.configsSkipped == 2)
        for diff in report.configDifferences {
            #expect(diff.classification == .skipped)
            #expect(diff.sourceHash == nil)
            #expect(diff.targetHash == nil)
        }
    }

    // Ports test_missing_source_in_repo
    @Test func missingSourceInRepo() throws {
        let repo = try TempDir(), home = try TempDir()
        let observed = Self.inspector(repo, home).inspectFile(TrackedFile(
            source: "nonexistent_source.conf", target: "~/.config/something.conf"))
        #expect(observed.state == .sourceMissing)
    }

    // Ports test_native_path_preservation_in_supported_flow
    @Test func nativePathPreservationInSupportedFlow() {
        let base = filePath(fromBytes: Array("/tmp/repo_".utf8) + [0xFF] + Array("_base".utf8))
        let home = filePath(fromBytes: Array("/tmp/home_".utf8) + [0xFE] + Array("_dir".utf8))
        let expectedSource = Array("/tmp/repo_".utf8) + [0xFF] + Array("_base/config/fish.conf".utf8)
        let expectedTarget = Array("/tmp/home_".utf8) + [0xFE] + Array("_dir/.config/fish.conf".utf8)

        #expect(pathBytes(resolveSourcePath("config/fish.conf", baseDir: base)) == expectedSource)
        #expect(pathBytes(expandTargetPath("~/.config/fish.conf", homeDir: home)) == expectedTarget)

        let inspector = ConfigInspector(repoRoot: base, homeDir: home,
                                        exclusions: ExclusionsSection(), overrides: [])
        let observed = inspector.inspectFile(TrackedFile(source: "config/fish.conf", target: "~/.config/fish.conf"))
        #expect(pathBytes(observed.sourcePath) == expectedSource)
        #expect(pathBytes(observed.targetPath) == expectedTarget)
        let replacement: [UInt8] = [0xEF, 0xBF, 0xBD]
        #expect(!containsSubsequence(pathBytes(observed.sourcePath), replacement))
        #expect(!containsSubsequence(pathBytes(observed.targetPath), replacement))
        #expect(observed.state == .sourceMissing)
    }

    // Ports test_non_utf8_manifest_file_is_explicitly_rejected
    @Test func nonUTF8ManifestFileIsExplicitlyRejected() throws {
        let temp = try TempDir()
        let manifestPath = "\(temp.path)/dotfilesync.toml"
        let bytes = Array("schema_version = 1\n# Invalid byte: ".utf8) + [0xFF]
            + Array("\n[[files]]\nsource = \"fish\"\ntarget = \"~/.config/fish\"\n".utf8)
        try Data(bytes).write(to: URL(fileURLWithPath: manifestPath))

        // Rust asserts `ErrorKind::InvalidData`; its Display is "stream did not contain valid UTF-8".
        #expect(throws: ManifestError.io(path: manifestPath, reason: "stream did not contain valid UTF-8")) {
            try loadManifest(manifestPath)
        }
    }

    // Ports test_apfs_filesystem_utf8_restriction_verified_honestly
    @Test func apfsFilesystemUTF8RestrictionVerifiedHonestly() throws {
        let temp = try TempDir()
        let name = Array("non_utf8_".utf8) + [0xFF] + Array("_test".utf8)
        let testPath = FilePath(temp.path).pushing(filePath(fromBytes: name))
        let fd = testPath.withPlatformString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644) }
        if fd < 0 {
            let code = errno
            // Rust: raw_os_error == 92 (EILSEQ) or ErrorKind::InvalidInput (EINVAL).
            #expect(code == EILSEQ || code == EINVAL, "Expected APFS EILSEQ or InvalidInput, got errno \(code)")

            try Self.write("\(temp.path)/dummy", "content")
            let inspector = ConfigInspector(repoRoot: FilePath(temp.path), homeDir: FilePath(temp.path),
                                            exclusions: ExclusionsSection(), overrides: [])
            let observed = inspector.inspectFile(TrackedFile(source: "dummy", target: "~/non_utf8_%FF_test"))
            #expect(observed.state == .missing)
            #expect(pathBytes(observed.targetPath).suffix(name.count).elementsEqual(name))
        } else {
            close(fd)
            _ = testPath.withPlatformString { unlink($0) }
        }
    }

    // Ports test_manifest_percent_encoded_path_bytes
    @Test func manifestPercentEncodedPathBytes() throws {
        let repo = try TempDir(), home = try TempDir()
        let observed = Self.inspector(repo, home).inspectFile(TrackedFile(
            source: "config/custom_%FF.conf", target: "~/.config/custom_%FE.conf"))
        let sourceSuffix = Array("/config/custom_".utf8) + [0xFF] + Array(".conf".utf8)
        let targetSuffix = Array("/.config/custom_".utf8) + [0xFE] + Array(".conf".utf8)
        #expect(pathBytes(observed.sourcePath).suffix(sourceSuffix.count).elementsEqual(sourceSuffix))
        #expect(pathBytes(observed.targetPath).suffix(targetSuffix.count).elementsEqual(targetSuffix))
        #expect(observed.state == .sourceMissing)
    }

    // Ports test_absent_machine_local_override_is_distinguishable_from_ordinary_missing
    @Test func absentMachineLocalOverrideIsDistinguishableFromOrdinaryMissing() throws {
        let repo = try TempDir(), home = try TempDir()
        try Self.write("\(repo.path)/ordinary_missing.conf", "managed_content = true\n")
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.files = [
            TrackedFile(source: "ordinary_missing.conf", target: "~/.config/ordinary_missing.conf"),
            TrackedFile(source: "fish/conf.d/local.fish", target: "~/.config/fish/conf.d/local.fish",
                        machineLocal: true),
        ]
        let configs = Self.inspector(repo, home, exclusions: manifest.exclusions, overrides: manifest.overrides)
            .inspectFiles(manifest.files)

        #expect(configs[0].state == .missing)
        #expect(configs[0].sourceHash != nil)
        #expect(configs[0].targetHash == nil)
        #expect(configs[1].state == .missing)
        #expect(configs[1].sourceHash == nil)
        #expect(configs[1].targetHash == nil)
        #expect(try #require(configs[1].diagnostic).contains("Machine-local override"))

        let report = compareStatus(manifest, brewResult: Self.enumerated(), configs: configs)
        #expect(report.summary.configsMissing == 2)
        let ordinary = try #require(report.configDifferences.first {
            rustPathEndsWith($0.target, "ordinary_missing.conf")
        })
        let local = try #require(report.configDifferences.first { rustPathEndsWith($0.target, "local.fish") })
        #expect(ordinary.sourceHash != nil)
        #expect(local.sourceHash == nil)
        #expect(local.targetHash == nil)
    }
}

private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard haystack.count >= needle.count else { return false }
    return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
}
