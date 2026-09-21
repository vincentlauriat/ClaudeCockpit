import CockpitShared
import XCTest
@testable import QuotaKit

/// The keychain is out of reach of a test run, so every case here exercises the
/// `~/.claude/.credentials.json` fallback in a temporary home.
final class CredentialStoreTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_789_128_000)

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ClaudePaths(home: home).claudeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Keychain lookup disabled: the test must read the file, not Vincent's login keychain.
    private func store() -> CredentialStore {
        CredentialStore(paths: ClaudePaths(home: home), keychainService: nil)
    }

    private func writeCredentials(_ json: String) throws {
        try Data(json.utf8).write(to: ClaudePaths(home: home).credentialsFile)
    }

    func testReadsWrappedOauthToken() throws {
        try writeCredentials("""
        { "claudeAiOauth": { "accessToken": "sk-ant-oat-abc",
                             "expiresAt": \((now.timeIntervalSince1970 + 3600) * 1000),
                             "scopes": ["user:inference"] } }
        """)
        XCTAssertEqual(try store().accessToken(now: now), "sk-ant-oat-abc")
    }

    func testReadsBareCredentialsObject() throws {
        try writeCredentials(#"{ "accessToken": "sk-ant-oat-bare" }"#)
        XCTAssertEqual(try store().accessToken(now: now), "sk-ant-oat-bare")
    }

    func testMissingFileIsNotFound() {
        XCTAssertThrowsError(try store().accessToken(now: now)) { error in
            XCTAssertEqual(error as? CredentialError, .notFound)
        }
    }

    func testExpiredTokenIsRejected() throws {
        try writeCredentials("""
        { "claudeAiOauth": { "accessToken": "stale",
                             "expiresAt": \((now.timeIntervalSince1970 - 60) * 1000) } }
        """)
        XCTAssertThrowsError(try store().accessToken(now: now)) { error in
            XCTAssertEqual(error as? CredentialError, .expired)
        }
    }

    func testTokenWithoutExpiryIsAccepted() throws {
        try writeCredentials(#"{ "claudeAiOauth": { "accessToken": "no-expiry" } }"#)
        XCTAssertEqual(try store().accessToken(now: now), "no-expiry")
    }

    func testEmptyTokenIsMalformed() throws {
        try writeCredentials(#"{ "claudeAiOauth": { "accessToken": "" } }"#)
        XCTAssertThrowsError(try store().accessToken(now: now)) { error in
            XCTAssertEqual(error as? CredentialError, .malformed)
        }
    }

    func testUnparsableFileIsMalformed() throws {
        try writeCredentials("not json at all")
        XCTAssertThrowsError(try store().accessToken(now: now)) { error in
            XCTAssertEqual(error as? CredentialError, .malformed)
        }
    }

    func testFileWithoutTokenIsMalformed() throws {
        try writeCredentials(#"{ "claudeAiOauth": { "refreshToken": "r" } }"#)
        XCTAssertThrowsError(try store().accessToken(now: now)) { error in
            XCTAssertEqual(error as? CredentialError, .malformed)
        }
    }
}
