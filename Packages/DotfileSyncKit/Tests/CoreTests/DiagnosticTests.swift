import Foundation
import Testing

@testable import Core

@Suite struct DiagnosticTests {
    @Test func detailIsOmittedWhenNil() throws {
        let data = try JSONEncoder().encode(Diagnostic.warning("careful"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["severity"] as? String == "warning")
        #expect(object["message"] as? String == "careful")
        #expect(object["detail"] == nil)
    }

    @Test func detailRoundTrips() throws {
        let original = Diagnostic.error("bad").withDetail("why")
        let decoded = try JSONDecoder().decode(Diagnostic.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func fixturesDirectoryIsReachable() {
        #expect(FileManager.default.fileExists(atPath: TestPaths.fixture("sample_manifest.toml").path))
    }
}
