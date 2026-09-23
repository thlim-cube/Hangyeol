import Foundation
import Security

/// Bounds a temporary runtime to the login session that installed it.
public struct SessionRuntimeLease: Codable, Equatable {
    public let userID: UInt32
    public let sessionID: UInt32

    public init(userID: UInt32, sessionID: UInt32) {
        self.userID = userID
        self.sessionID = sessionID
    }

    public func permits(userID: UInt32, sessionID: UInt32?) -> Bool {
        self.userID == userID && self.sessionID == sessionID
    }

    public static func currentSessionID() -> UInt32? {
        var session: SecuritySessionId = 0
        guard SessionGetInfo(callerSecuritySession, &session, nil) == errSecSuccess,
              session != noSecuritySession else { return nil }
        return session
    }

    public static func fileURL(for appURL: URL) -> URL {
        appURL.deletingLastPathComponent().appendingPathComponent("session.json")
    }

    public static func isSessionApp(_ appURL: URL) -> Bool {
        let parent = appURL.deletingLastPathComponent()
        return appURL.lastPathComponent == "Hangyeol.app"
            && parent.lastPathComponent.hasPrefix("hangyeol-session.")
            && ["/tmp", "/private/tmp"].contains(parent.deletingLastPathComponent().path)
    }

    public static func load(for appURL: URL) -> Self? {
        guard let data = try? Data(contentsOf: fileURL(for: appURL)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
