import AppKit
import Carbon
import Darwin
import Foundation
import HangyeolInstallerSupport
import Security

private let identity = InstallerInputSourceIdentity(
    bundleID: "com.thlim.inputmethod.Hangyeol",
    modeID: "com.thlim.inputmethod.Hangyeol",
    legacyBundleIDs: [
        "com.thlim.hangyeol.inputmethod",
        "com.meapri.hangyeol.inputmethod",
        "com.pritype.inputmethod.v2"
    ]
)

private enum HelperExit {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let invalidArguments: Int32 = 64
}

private func stringProperty(
    _ key: CFString,
    from source: TISInputSource
) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
        return nil
    }
    return Unmanaged<CFString>
        .fromOpaque(pointer)
        .takeUnretainedValue() as String
}

private func boolProperty(
    _ key: CFString,
    from source: TISInputSource
) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
        return false
    }
    return Unmanaged<CFBoolean>
        .fromOpaque(pointer)
        .takeUnretainedValue() == kCFBooleanTrue
}

private func candidate(
    for source: TISInputSource
) -> InstallerInputSourceCandidate? {
    guard let sourceID = stringProperty(
        kTISPropertyInputSourceID,
        from: source
    ) else {
        return nil
    }
    let sourceType = stringProperty(kTISPropertyInputSourceType, from: source)
    let kind: InstallerInputSourceKind
    if sourceType == kTISTypeKeyboardInputMethodModeEnabled as String {
        kind = .inputMethodParent
    } else if sourceType == kTISTypeKeyboardInputMode as String {
        kind = .inputMode
    } else {
        kind = .other
    }
    return InstallerInputSourceCandidate(
        sourceID: sourceID,
        bundleID: stringProperty(kTISPropertyBundleID, from: source),
        modeID: stringProperty(kTISPropertyInputModeID, from: source),
        kind: kind,
        isEnabled: boolProperty(kTISPropertyInputSourceIsEnabled, from: source),
        isEnableCapable: boolProperty(
            kTISPropertyInputSourceIsEnableCapable,
            from: source
        ),
        isSelectCapable: boolProperty(
            kTISPropertyInputSourceIsSelectCapable,
            from: source
        ),
        isASCIICapable: boolProperty(
            kTISPropertyInputSourceIsASCIICapable,
            from: source
        )
    )
}

private func fallbackSources() -> [TISInputSource] {
    var sources: [TISInputSource] = []
    if let layout = TISCopyCurrentKeyboardLayoutInputSource()?
        .takeRetainedValue() {
        sources.append(layout)
    }
    if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?
        .takeRetainedValue() {
        sources.append(ascii)
    }
    if let installed = TISCreateInputSourceList(nil, false)?
        .takeRetainedValue() as? [TISInputSource] {
        sources.append(contentsOf: installed)
    }
    return sources
}

private func printPreparationResult(
    selectedBefore: Bool,
    fallbackSourceID: String?,
    fallbackWasEnabled: Bool
) {
    print("selected-before=\(selectedBefore)")
    print("fallback-source-id=\(fallbackSourceID ?? "-")")
    print("fallback-was-enabled=\(fallbackWasEnabled)")
}

private func disableFallbackIfItIsNotSelected(
    _ fallback: TISInputSource,
    sourceID: String
) {
    guard let selected = TISCopyCurrentKeyboardInputSource()?
        .takeRetainedValue(),
          candidate(for: selected)?.sourceID != sourceID else {
        return
    }
    _ = TISDisableInputSource(fallback)
}

private func prepareForUpdate() -> Int32 {
    guard let current = TISCopyCurrentKeyboardInputSource()?
        .takeRetainedValue(),
          let currentCandidate = candidate(for: current) else {
        fputs("prepare-update: current input source is unavailable\n", stderr)
        return HelperExit.failure
    }
    guard identity.owns(currentCandidate) else {
        printPreparationResult(
            selectedBefore: false,
            fallbackSourceID: nil,
            fallbackWasEnabled: true
        )
        return HelperExit.success
    }

    let sourceCandidates = fallbackSources().compactMap { source in
        candidate(for: source).map { (source, $0) }
    }
    let safeCandidates = InputSourceLifecycleRules.safeFallbackCandidates(
        from: sourceCandidates.map(\.1),
        identity: identity
    )
    for fallbackCandidate in safeCandidates {
        guard let fallback = sourceCandidates.first(where: {
            $0.1.sourceID == fallbackCandidate.sourceID
        })?.0 else {
            continue
        }
        let wasEnabled = fallbackCandidate.isEnabled
        if !wasEnabled,
           TISEnableInputSource(fallback) != noErr {
            continue
        }
        guard TISSelectInputSource(fallback) == noErr else {
            if !wasEnabled {
                disableFallbackIfItIsNotSelected(
                    fallback,
                    sourceID: fallbackCandidate.sourceID
                )
            }
            continue
        }

        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let selected = TISCopyCurrentKeyboardInputSource()?
                .takeRetainedValue(),
               let selectedCandidate = candidate(for: selected),
               !identity.owns(selectedCandidate) {
                printPreparationResult(
                    selectedBefore: true,
                    fallbackSourceID: fallbackCandidate.sourceID,
                    fallbackWasEnabled: wasEnabled
                )
                return HelperExit.success
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(0.05)
            )
        } while Date() < deadline
        if !wasEnabled {
            disableFallbackIfItIsNotSelected(
                fallback,
                sourceID: fallbackCandidate.sourceID
            )
        }
    }

    fputs("prepare-update: safe fallback selection failed\n", stderr)
    return HelperExit.failure
}

private func snapshotUpdate() -> Int32 {
    guard let current = TISCopyCurrentKeyboardInputSource()?
        .takeRetainedValue(),
          let currentCandidate = candidate(for: current) else {
        fputs("snapshot-update: current input source is unavailable\n", stderr)
        return HelperExit.failure
    }
    printPreparationResult(
        selectedBefore: identity.owns(currentCandidate),
        fallbackSourceID: nil,
        fallbackWasEnabled: true
    )
    return HelperExit.success
}

private func processIsRunning(name: String, userID: uid_t) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "-u", String(userID), name]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return true
    }
}

private func waitForProcessExit(arguments: ArraySlice<String>) -> Int32 {
    guard arguments.count >= 2,
          let timeout = TimeInterval(arguments.first ?? ""),
          timeout > 0 else {
        return HelperExit.invalidArguments
    }
    let names = arguments.dropFirst()
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if !names.contains(where: {
            processIsRunning(name: $0, userID: getuid())
        }) {
            return HelperExit.success
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return HelperExit.failure
}

private func runningHangyeolExecutablePaths() -> [String]? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "-u", String(getuid()), "Hangyeol"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let pidList = String(data: data, encoding: .utf8) else {
            return nil
        }
        var paths: [String] = []
        for value in pidList.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(value) else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { return nil }
            let bytes = path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            paths.append(String(decoding: bytes, as: UTF8.self))
        }
        return paths
    } catch {
        return nil
    }
}

private func verifySessionRuntime(arguments: ArraySlice<String>) -> Int32 {
    guard arguments.count == 2,
          let expectedPath = arguments.first,
          expectedPath.hasPrefix("/private/tmp/hangyeol-session."),
          expectedPath.hasSuffix("/Hangyeol.app/Contents/MacOS/Hangyeol"),
          let selectedArgument = arguments.dropFirst().first,
          selectedArgument == "true" || selectedArgument == "false" else {
        return HelperExit.invalidArguments
    }
    let deadline = Date().addingTimeInterval(3)
    repeat {
        if let paths = runningHangyeolExecutablePaths(),
           paths.count == 1,
           URL(fileURLWithPath: paths[0]).resolvingSymlinksInPath().path
             == URL(fileURLWithPath: String(expectedPath)).resolvingSymlinksInPath().path,
           let sources = TISCreateInputSourceList(nil, false)?
             .takeRetainedValue() as? [TISInputSource],
           InputSourceLifecycleRules.roster(
             from: sources.compactMap(candidate(for:)), identity: identity
           ).isEnabled,
           let selectedSource = TISCopyCurrentKeyboardInputSource()?
             .takeRetainedValue(),
           let selectedCandidate = candidate(for: selectedSource),
           identity.owns(selectedCandidate) == (selectedArgument == "true") {
            print("session-runtime-path=\(paths[0])")
            return HelperExit.success
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    fputs("session-runtime: process or input-source state differs\n", stderr)
    return HelperExit.failure
}

private final class CurrentSessionRuntimeHost: SessionRuntimeHost {
    private let installedURL = URL(fileURLWithPath: "/Library/Input Methods/Hangyeol.app")
    private let candidateURL: URL
    private var originalSource: TISInputSource?
    private var selectedBefore = false
    private var fallbackID: String?

    init(appPath: String) {
        candidateURL = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
    }

    private func metadata(_ url: URL) -> NSDictionary? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func reject(_ reason: String) -> Bool {
        fputs("session-activation deferred: \(reason)\n", stderr)
        return false
    }

    func validateCandidate() -> Bool {
        guard SessionRuntimeLease.isSessionApp(candidateURL),
              let lease = SessionRuntimeLease.load(for: candidateURL),
              lease.permits(userID: getuid(), sessionID: SessionRuntimeLease.currentSessionID()),
              let installed = metadata(installedURL),
              let proposed = metadata(candidateURL) else { return reject("path, lease, or metadata mismatch") }
        for key in ["CFBundleIdentifier",
                    "InputMethodServerControllerClass", "ComponentInputModeDict",
                    "tsInputMethodCharacterRepertoireKey"] {
            guard let lhs = installed[key] as? NSObject,
                  let rhs = proposed[key] as? NSObject, lhs.isEqual(rhs) else { return reject("registration key \(key) differs") }
        }
        guard SessionRuntimeActivation.compatibleConnectionName(
            installed: installed["InputMethodConnectionName"] as? String,
            proposed: proposed["InputMethodConnectionName"] as? String
        ) else { return reject("connection name differs; keep the current runtime until logout") }
        var installedCode: SecStaticCode?
        var proposedCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(installedURL as CFURL, [], &installedCode) == errSecSuccess,
              let installedCode,
              SecStaticCodeCheckValidity(installedCode, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(candidateURL as CFURL, [], &proposedCode) == errSecSuccess,
              let proposedCode,
              SecStaticCodeCheckValidity(proposedCode, [], requirement) == errSecSuccess else {
            return reject("candidate does not satisfy the installed signature")
        }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let currentCandidate = candidate(for: current),
              knownProcesses() != nil else { return reject("input source or running process is unknown") }
        originalSource = current
        selectedBefore = identity.owns(currentCandidate)
        return true
    }

    private func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(kTISPropertyInputSourceID, from: source)
    }

    func prepareInputSource() -> Bool {
        guard selectedBefore else { return true }
        // Selecting a fallback asks the old IMK to commit its active composition
        // and prevents macOS from relaunching it during the process handoff.
        guard prepareForUpdate() == HelperExit.success else { return false }
        fallbackID = currentSourceID()
        return fallbackID != nil
    }

    private func knownProcesses() -> [(pid_t, String)]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "-u", String(getuid()), "Hangyeol"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 1 { return [] }
            guard process.terminationStatus == 0 else { return nil }
            var result: [(pid_t, String)] = []
            for value in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard let pid = Int32(value) else { return nil }
                var buffer = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
                let path = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                guard executable.path == installedURL.appendingPathComponent("Contents/MacOS/Hangyeol").path
                        || (SessionRuntimeLease.isSessionApp(app)
                            && path.hasSuffix("/Contents/MacOS/Hangyeol")) else { return nil }
                result.append((pid, executable.path))
            }
            return result
        } catch { return nil }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    func stopCurrentRuntime() -> Bool {
        guard let processes = knownProcesses() else { return false }
        for (pid, _) in processes {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            guard app.isTerminated || app.terminate() else { return false }
        }
        return waitUntil { self.knownProcesses()?.isEmpty == true }
    }

    private func launch(_ appURL: URL) -> Bool {
        // LaunchServices must know which instance serves the registered bundle.
        // Executing Contents/MacOS/Hangyeol directly lets TIS launch a duplicate
        // canonical process when the source is selected again.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-g", appURL.path]
        do {
            try process.run()
            guard waitUntil({ !process.isRunning }) else {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        } catch { return false }
    }

    func launchCandidate() -> Bool { launch(candidateURL) }

    private func verifyRuntime(at appURL: URL) -> Bool {
        let expected = appURL.appendingPathComponent("Contents/MacOS/Hangyeol").path
        var consecutivePasses = 0
        return waitUntil {
            guard let processes = self.knownProcesses(), processes.count == 1,
                  processes[0].1 == expected,
                  NSRunningApplication(processIdentifier: processes[0].0)?.isFinishedLaunching == true,
                  let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource],
                  InputSourceLifecycleRules.roster(from: sources.compactMap(candidate(for:)), identity: identity).isEnabled else {
                consecutivePasses = 0
                return false
            }
            consecutivePasses += 1
            return consecutivePasses >= 3
        }
    }

    func verifyCandidate() -> Bool { verifyRuntime(at: candidateURL) }

    func restoreInputSource() -> Bool {
        guard selectedBefore, let originalSource else { return true }
        guard let currentID = currentSourceID() else { return false }
        let originalID = stringProperty(kTISPropertyInputSourceID, from: originalSource)
        if currentID == originalID { return true }
        // The user can choose another source while installation is finishing.
        guard SessionRuntimeActivation.shouldRestoreSelection(
            selectedBefore: selectedBefore, currentSourceID: currentID, fallbackID: fallbackID
        ) else { return true }
        guard TISSelectInputSource(originalSource) == noErr else { return false }
        return waitUntil { self.currentSourceID() == originalID }
    }

    func restoreInstalledRuntime() -> Bool {
        if verifyRuntime(at: installedURL) { return restoreInputSource() }
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let currentCandidate = candidate(for: current), identity.owns(currentCandidate) {
            guard prepareForUpdate() == HelperExit.success else { return false }
            fallbackID = currentSourceID()
        }
        guard stopCurrentRuntime(), launch(installedURL), verifyRuntime(at: installedURL),
              restoreInputSource() else { return false }
        return verifyRuntime(at: installedURL)
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    exit(HelperExit.invalidArguments)
}

switch command {
case "--session-id":
    guard arguments.count == 1,
          let sessionID = SessionRuntimeLease.currentSessionID() else {
        exit(HelperExit.failure)
    }
    print(sessionID)
    exit(HelperExit.success)
case "--activate-session-runtime":
    guard arguments.count == 2, let appPath = arguments.dropFirst().first else {
        exit(HelperExit.invalidArguments)
    }
    let result = SessionRuntimeActivation.apply(using: CurrentSessionRuntimeHost(appPath: appPath))
    print("session-activation=\(result)")
    exit(result == .applied ? HelperExit.success : HelperExit.failure)
case "--snapshot-update":
    guard arguments.count == 1 else { exit(HelperExit.invalidArguments) }
    exit(snapshotUpdate())
case "--prepare-update":
    guard arguments.count == 1 else { exit(HelperExit.invalidArguments) }
    exit(prepareForUpdate())
case "--wait-for-process-exit":
    exit(waitForProcessExit(arguments: arguments.dropFirst()))
case "--verify-session-runtime":
    exit(verifySessionRuntime(arguments: arguments.dropFirst()))
default:
    exit(HelperExit.invalidArguments)
}
