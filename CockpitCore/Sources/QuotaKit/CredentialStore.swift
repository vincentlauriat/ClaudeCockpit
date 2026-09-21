import CockpitShared
import Foundation

/// Anything able to hand out a Claude Code OAuth access token.
public protocol TokenProviding: Sendable {
    func accessToken() throws -> String
}

/// Reads the OAuth access token that Claude Code stores for the logged-in user.
///
/// - macOS: keychain item `Claude Code-credentials`, read through `/usr/bin/security`,
///   the same tool Claude Code uses to write it, so no extra ACL prompt appears.
/// - Fallback: `paths.credentialsFile` (`~/.claude/.credentials.json`).
///
/// The token is never persisted nor logged by this module; it only lives in memory
/// for the duration of the request.
public struct CredentialStore: TokenProviding, Sendable {
    public static let defaultKeychainService = "Claude Code-credentials"

    private let paths: ClaudePaths
    /// Keychain item to look up. `nil` skips the keychain and reads the file only
    /// (used by tests, which must not depend on the machine's login keychain).
    private let keychainService: String?

    public init(paths: ClaudePaths = .live,
                keychainService: String? = CredentialStore.defaultKeychainService) {
        self.paths = paths
        self.keychainService = keychainService
    }

    public func accessToken() throws -> String {
        try accessToken(now: Date())
    }

    func accessToken(now: Date) throws -> String {
        guard let json = readKeychain() ?? readFile() else { throw CredentialError.notFound }
        return try Self.parse(json, now: now)
    }

    private func readKeychain() -> Data? {
        guard let keychainService else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        // `security -w` prints the secret followed by a newline.
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.data(using: .utf8)
    }

    private func readFile() -> Data? {
        try? Data(contentsOf: paths.credentialsFile)
    }

    /// Accepts both the wrapped shape (`{"claudeAiOauth": {…}}`) and a bare credentials object.
    static func parse(_ data: Data, now: Date) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.malformed
        }
        let credentials = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = credentials["accessToken"] as? String, !token.isEmpty else {
            throw CredentialError.malformed
        }
        if let expiresAt = (credentials["expiresAt"] as? NSNumber)?.doubleValue {
            // Stored in milliseconds since the epoch.
            if expiresAt / 1000 <= now.timeIntervalSince1970 { throw CredentialError.expired }
        }
        return token
    }
}
