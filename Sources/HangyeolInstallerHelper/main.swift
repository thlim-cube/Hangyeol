import Carbon
import Foundation
import HangyeolInstallerSupport

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

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    exit(HelperExit.invalidArguments)
}

switch command {
case "--prepare-update":
    guard arguments.count == 1 else { exit(HelperExit.invalidArguments) }
    exit(prepareForUpdate())
case "--wait-for-process-exit":
    exit(waitForProcessExit(arguments: arguments.dropFirst()))
default:
    exit(HelperExit.invalidArguments)
}
