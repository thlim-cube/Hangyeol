import Foundation
import Security
import HangyeolCore

public struct AppArtifactIdentity: Equatable, Sendable, CustomStringConvertible {
    public let appPath: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let signingIdentifier: String
    public let codeDirectoryHash: String
    public let teamIdentifier: String
    public let signingAuthority: String

    public var description: String {
        "path=\(appPath), bundle=\(bundleID), version=\(version), build=\(build), "
            + "signingIdentifier=\(signingIdentifier), team=\(teamIdentifier), "
            + "cdhash=\(codeDirectoryHash), authority=\(signingAuthority)"
    }
}

public struct ArtifactComparison: Sendable {
    public let installed: AppArtifactIdentity
    public let packaged: AppArtifactIdentity
    public let mismatches: [String]

    public var isMatch: Bool { mismatches.isEmpty }
}

public struct RunningArtifactIdentity: Equatable, Sendable, CustomStringConvertible {
    public let pid: pid_t
    public let executablePath: String
    public let signingIdentifier: String
    public let codeDirectoryHash: String
    public let teamIdentifier: String
    public let signingAuthority: String

    public var description: String {
        "pid=\(pid), executable=\(executablePath), "
            + "signingIdentifier=\(signingIdentifier), team=\(teamIdentifier), "
            + "cdhash=\(codeDirectoryHash), authority=\(signingAuthority)"
    }
}

public enum ArtifactInspectionError: LocalizedError {
    case appMissing(String)
    case infoPlistMissing(String)
    case malformedInfoPlist(String)
    case missingInfoKey(String, String)
    case commandFailed(String, Int32, String)
    case dynamicCodeInvalid(pid_t, OSStatus)
    case packagedAppMissing(String)
    case unexpectedProduct(String)

    public var errorDescription: String? {
        switch self {
        case let .appMissing(path):
            "앱 번들을 찾을 수 없습니다: \(path)"
        case let .infoPlistMissing(path):
            "Info.plist를 찾을 수 없습니다: \(path)"
        case let .malformedInfoPlist(path):
            "Info.plist를 읽을 수 없습니다: \(path)"
        case let .missingInfoKey(key, path):
            "Info.plist의 \(key) 값이 없습니다: \(path)"
        case let .commandFailed(command, status, output):
            "명령 실패(\(status)): \(command)\n\(output)"
        case let .dynamicCodeInvalid(pid, status):
            "실행 중인 코드의 동적 서명이 유효하지 않습니다: pid=\(pid), status=\(status)"
        case let .packagedAppMissing(path):
            "PKG payload에서 Hangyeol.app을 찾을 수 없습니다: \(path)"
        case let .unexpectedProduct(details):
            "한결 제품 식별자가 예상과 다릅니다: \(details)"
        }
    }
}

public enum ArtifactInspector {
    public static let defaultInstalledAppURL = URL(
        fileURLWithPath: "/Library/Input Methods/Hangyeol.app",
        isDirectory: true
    )

    public static func inspectApp(at appURL: URL) throws -> AppArtifactIdentity {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: appURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ArtifactInspectionError.appMissing(appURL.path)
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else {
            throw ArtifactInspectionError.infoPlistMissing(infoURL.path)
        }
        guard let info = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw ArtifactInspectionError.malformedInfoPlist(infoURL.path)
        }

        let bundleID = try requiredString("CFBundleIdentifier", in: info, path: infoURL.path)
        let version = try requiredString(
            "CFBundleShortVersionString",
            in: info,
            path: infoURL.path
        )
        let build = try requiredString("CFBundleVersion", in: info, path: infoURL.path)

        _ = try run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--verbose=2", appURL.path]
        )
        let signature = try run(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", appURL.path]
        )
        let signatureFields = parseCodeSignatureDetails(signature)

        guard bundleID == ProductIdentity.bundleID else {
            throw ArtifactInspectionError.unexpectedProduct("bundle=\(bundleID)")
        }
        let signingIdentifier = signatureFields["Identifier"] ?? ""
        guard signingIdentifier == ProductIdentity.bundleID else {
            throw ArtifactInspectionError.unexpectedProduct(
                "signingIdentifier=\(signingIdentifier)"
            )
        }
        let codeDirectoryHash = signatureFields["CDHash"] ?? ""
        guard !codeDirectoryHash.isEmpty else {
            throw ArtifactInspectionError.unexpectedProduct("CDHash=<없음>")
        }

        return AppArtifactIdentity(
            appPath: appURL.standardizedFileURL.path,
            bundleID: bundleID,
            version: version,
            build: build,
            signingIdentifier: signingIdentifier,
            codeDirectoryHash: codeDirectoryHash,
            teamIdentifier: signatureFields["TeamIdentifier"] ?? "",
            signingAuthority: signatureFields["Authority"] ?? ""
        )
    }

    public static func inspectPackage(at packageURL: URL) throws -> AppArtifactIdentity {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hangyeol-e2e-pkg-\(UUID().uuidString)", isDirectory: true)
        let expandedURL = temporaryRoot.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        _ = try run(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--expand-full", packageURL.path, expandedURL.path]
        )
        guard let packagedAppURL = findPackagedApp(in: expandedURL) else {
            throw ArtifactInspectionError.packagedAppMissing(packageURL.path)
        }
        return try inspectApp(at: packagedAppURL)
    }

    /// Reads the code object already loaded by a running process. Inspecting the
    /// bundle path alone is insufficient after an atomic package update because a
    /// live IMK server can continue executing the unlinked previous binary.
    public static func inspectRunningProcess(pid: pid_t) throws -> RunningArtifactIdentity {
        try validateRunningCode(pid: pid)
        let signature = try run(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", "+\(pid)"]
        )
        let fields = parseCodeSignatureDetails(signature)
        let signingIdentifier = fields["Identifier"] ?? ""
        guard signingIdentifier == ProductIdentity.bundleID else {
            throw ArtifactInspectionError.unexpectedProduct(
                "running signingIdentifier=\(signingIdentifier)"
            )
        }
        let codeDirectoryHash = fields["CDHash"] ?? ""
        guard !codeDirectoryHash.isEmpty else {
            throw ArtifactInspectionError.unexpectedProduct("running CDHash=<없음>")
        }

        return RunningArtifactIdentity(
            pid: pid,
            executablePath: fields["Executable"] ?? "",
            signingIdentifier: signingIdentifier,
            codeDirectoryHash: codeDirectoryHash,
            teamIdentifier: fields["TeamIdentifier"] ?? "",
            signingAuthority: fields["Authority"] ?? ""
        )
    }

    /// `codesign --verify +PID` can print `dynamically valid` and still exit 1
    /// with `Invalid argument` on macOS 26. Validate the live code object through
    /// Security.framework, whose dynamic-code API is the source of truth.
    static func validateRunningCode(pid: pid_t) throws {
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: pid)
        ] as CFDictionary
        var runningCode: SecCode?
        let lookupStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &runningCode
        )
        guard lookupStatus == errSecSuccess, let runningCode else {
            throw ArtifactInspectionError.dynamicCodeInvalid(pid, lookupStatus)
        }

        let validityStatus = SecCodeCheckValidity(
            runningCode,
            SecCSFlags(),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw ArtifactInspectionError.dynamicCodeInvalid(pid, validityStatus)
        }
    }

    public static func compare(
        installed: AppArtifactIdentity,
        packaged: AppArtifactIdentity
    ) -> ArtifactComparison {
        var mismatches: [String] = []
        compare("bundle ID", installed.bundleID, packaged.bundleID, into: &mismatches)
        compare("version", installed.version, packaged.version, into: &mismatches)
        compare("build", installed.build, packaged.build, into: &mismatches)
        compare(
            "signing identifier",
            installed.signingIdentifier,
            packaged.signingIdentifier,
            into: &mismatches
        )
        compare(
            "CDHash",
            installed.codeDirectoryHash,
            packaged.codeDirectoryHash,
            into: &mismatches
        )
        compare(
            "team identifier",
            installed.teamIdentifier,
            packaged.teamIdentifier,
            into: &mismatches
        )
        compare(
            "signing authority",
            installed.signingAuthority,
            packaged.signingAuthority,
            into: &mismatches
        )
        return ArtifactComparison(
            installed: installed,
            packaged: packaged,
            mismatches: mismatches
        )
    }

    public static func compare(
        running: RunningArtifactIdentity,
        packaged: AppArtifactIdentity
    ) -> [String] {
        [
            ("running signing identifier", running.signingIdentifier, packaged.signingIdentifier),
            ("running CDHash", running.codeDirectoryHash, packaged.codeDirectoryHash),
            ("running team identifier", running.teamIdentifier, packaged.teamIdentifier),
            ("running signing authority", running.signingAuthority, packaged.signingAuthority)
        ].compactMap { label, process, package in
            process == package ? nil : "\(label): process=\(process), package=\(package)"
        }
    }

    static func parseCodeSignatureDetails(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            if (
                key == "Executable"
                    || key == "Identifier"
                    || key == "CDHash"
                    || key == "TeamIdentifier"
                    || key == "Authority"
            ),
               fields[key] == nil {
                fields[key] = parts[1]
            }
        }
        return fields
    }

    private static func requiredString(
        _ key: String,
        in info: [String: Any],
        path: String
    ) throws -> String {
        guard let value = info[key] as? String, !value.isEmpty else {
            throw ArtifactInspectionError.missingInfoKey(key, path)
        }
        return value
    }

    private static func findPackagedApp(in rootURL: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "Hangyeol.app" {
            return url
        }
        return nil
    }

    private static func compare(
        _ label: String,
        _ installed: String,
        _ packaged: String,
        into mismatches: inout [String]
    ) {
        guard installed != packaged else { return }
        mismatches.append("\(label): installed=\(installed), package=\(packaged)")
    }

    @discardableResult
    private static func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let stdout = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let combined = stdout + stderr
        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            throw ArtifactInspectionError.commandFailed(
                command,
                process.terminationStatus,
                combined
            )
        }
        return combined
    }
}
