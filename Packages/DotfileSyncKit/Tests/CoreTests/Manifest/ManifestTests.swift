import Core
import Foundation
import System
import Testing

/// Ports of the inline `mod tests` in crates/dotfilesync-core/src/manifest/mod.rs, plus
/// fixture and round-trip checks.
struct ManifestTests {
    private func isValidationError(_ error: any Error) -> Bool {
        if case .validation = error as? ManifestError { true } else { false }
    }

    // Ports Rust test: manifest::tests::test_valid_manifest_parsing
    @Test func validManifestParsing() throws {
        let toml = """
            schema_version = 1

            [metadata]
            name = "my-test"
            description = "Test configuration"

            [package_managers.homebrew]
            formulae = ["git", "fish"]
            casks = ["zed"]

            [[files]]
            source = "fish/config.fish"
            target = "~/.config/fish/config.fish"

            [exclusions]
            paths = ["fish/conf.d/local.fish"]
            patterns = ["*.backup.*"]

            [[overrides]]
            target = "~/.config/fish/conf.d/local.fish"
            description = "Private secrets"
            """
        let manifest = try parseManifest(toml)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.packageManagers.homebrew.formulae == ["git", "fish"])
        #expect(manifest.packageManagers.homebrew.casks == ["zed"])
        #expect(manifest.files.count == 1)
        #expect(manifest.exclusions.paths.count == 1)
        #expect(manifest.overrides.count == 1)
    }

    // Ports Rust test: manifest::tests::test_unsupported_version
    @Test func unsupportedVersion() {
        #expect(performing: { _ = try parseManifest("schema_version = 99\n") }, throws: isValidationError)
    }

    // Ports Rust test: manifest::tests::test_directory_traversal_rejected
    @Test func directoryTraversalRejected() {
        let toml = """
            schema_version = 1

            [[files]]
            source = "../../../etc/passwd"
            target = "~/.config/evil"
            """
        #expect(performing: { _ = try parseManifest(toml) }, throws: isValidationError)
    }

    // Ports Rust test: manifest::tests::test_sensitive_credential_path_rejected
    @Test func sensitiveCredentialPathRejected() {
        let toml = """
            schema_version = 1

            [[files]]
            source = "ssh/id_rsa"
            target = "~/.ssh/id_rsa"
            """
        #expect(performing: { _ = try parseManifest(toml) }, throws: isValidationError)
    }

    // Ports Rust test: manifest::tests::test_percent_encoded_path_roundtrip
    @Test func percentEncodedPathRoundtrip() {
        let path = FilePath("fish/config.fish")
        #expect(encodeManifestPathBytes(path) == "fish/config.fish")
        #expect(decodeManifestPathBytes("fish/config.fish") == path)

        let rawBytes = Array("fish/custom_".utf8) + [0xFF] + Array(".conf".utf8)
        let encoded = encodeManifestPathBytes(Self.path(rawBytes))
        #expect(encoded == "fish/custom_%FF.conf")
        #expect(Self.bytes(decodeManifestPathBytes(encoded)) == rawBytes)

        let rawBytes2 = Array(".config/sub_".utf8) + [0xFE, 0xED] + Array("/test.conf".utf8)
        let encoded2 = encodeManifestPathBytes(Self.path(rawBytes2))
        #expect(encoded2 == ".config/sub_%FE%ED/test.conf")
        #expect(Self.bytes(decodeManifestPathBytes(encoded2)) == rawBytes2)
    }

    // Not a Rust port: Display strings asserted for parity (A3).
    @Test func errorMessagesMatchRust() {
        #expect(ManifestError.validation(1, "- x").description == "Manifest validation failed with 1 errors: - x")
        #expect(ManifestError.unknownProfile(name: "nope").description == "Unknown profile 'nope'")
        #expect(ManifestError.profileCycle(cycle: "a -> b -> a").description == "Profile cycle detected: a -> b -> a")
        #expect(
            ValidationError.unknownProfile(name: "missing", context: "select.default").description
                == "Unknown profile 'missing' referenced from select.default"
        )
        #expect(
            ValidationError.unsupportedSchemaVersion(version: 99, expected: 1).localizedDescription
                == "Unsupported schema version 99; expected 1"
        )
    }

    // Not a Rust port: path helpers match Rust `Path::join` behaviour.
    @Test func expandAndResolvePaths() {
        let home = FilePath("/Users/me")
        #expect(expandTargetPath("~/.config/x", homeDir: home) == FilePath("/Users/me/.config/x"))
        #expect(expandTargetPath("~", homeDir: home) == home)
        #expect(expandTargetPath("/etc/x", homeDir: home) == FilePath("/etc/x"))
        #expect(resolveSourcePath("fish/a%FFb", baseDir: FilePath("/repo")).string.hasPrefix("/repo/fish/a"))
    }

    // Covers A2: fixtures/sample_manifest.toml loads and validates.
    @Test func sampleFixtureLoads() throws {
        let manifest = try loadManifest(TestPaths.fixture("sample_manifest.toml"))
        #expect(manifest.metadata?.name == "fixture-test-env")
        #expect(manifest.files.count == 4)
        #expect(manifest.files[3].machineLocal)
    }

    // Not a Rust port: missing file yields the Rust io::Error display.
    @Test func missingFileIoError() {
        #expect {
            _ = try loadManifest("/nonexistent/dotfilesync.toml")
        } throws: { error in
            "\(error)" == "Failed to read manifest file '/nonexistent/dotfilesync.toml': No such file or directory (os error 2)"
        }
    }

    // Not a Rust port: TOML serialization round-trips the repo manifest.
    @Test func serializeRoundTrip() throws {
        let manifest = try loadManifest(TestPaths.repoRoot.appendingPathComponent("dotfilesync.toml"))
        let text = try serializeManifest(manifest)
        #expect(try parseManifest(text) == manifest)
    }

    // Not a Rust port: JSON keys follow serde names and skip rules.
    @Test func jsonKeysMatchSerde() throws {
        let file = TrackedFile(source: "a", target: "b")
        let json = try #require(String(data: JSONEncoder().encode(file), encoding: .utf8))
        #expect(json.contains("\"machine_local\":false"))
        #expect(!json.contains("mode"))
        #expect(!json.contains("description"))
        let symlink = TrackedFile(source: "a", target: "b", mode: .symlink)
        #expect(try String(data: JSONEncoder().encode(symlink), encoding: .utf8)?.contains("\"mode\":\"symlink\"") == true)
    }

    // Not a Rust port: unknown keys are ignored, as serde does by default.
    @Test func unknownKeysIgnored() throws {
        let manifest = try parseManifest("schema_version = 1\nfuture_key = true\n[setup]\nextra = 1\n")
        #expect(manifest.setup == SetupSection())
    }

    private static func path(_ bytes: [UInt8]) -> FilePath {
        var cString = bytes.map { CChar(bitPattern: $0) }
        cString.append(0)
        return cString.withUnsafeBufferPointer { FilePath(platformString: $0.baseAddress!) }
    }

    private static func bytes(_ path: FilePath) -> [UInt8] {
        path.withPlatformString { pointer in
            var result: [UInt8] = []
            var cursor = pointer
            while cursor.pointee != 0 {
                result.append(UInt8(bitPattern: cursor.pointee))
                cursor += 1
            }
            return result
        }
    }
}
