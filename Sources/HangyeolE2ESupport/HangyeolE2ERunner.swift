import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import HangyeolCore

public struct HangyeolE2EConfiguration: Sendable {
    public let packageURL: URL?
    public let installedAppURL: URL
    public let chromeAppURL: URL
    public let preflightOnly: Bool
    public let scenarioFilter: String?

    public init(
        packageURL: URL? = nil,
        installedAppURL: URL = ArtifactInspector.defaultInstalledAppURL,
        chromeAppURL: URL = URL(
            fileURLWithPath: "/Applications/Google Chrome.app",
            isDirectory: true
        ),
        preflightOnly: Bool = false,
        scenarioFilter: String? = nil
    ) {
        self.packageURL = packageURL
        self.installedAppURL = installedAppURL
        self.chromeAppURL = chromeAppURL
        self.preflightOnly = preflightOnly
        self.scenarioFilter = scenarioFilter
    }
}

public enum HangyeolE2EError: LocalizedError {
    case preflight([String])
    case conditionTimedOut(String)
    case unavailable(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case let .preflight(messages):
            "E2E preflight 실패:\n- " + messages.joined(separator: "\n- ")
        case let .conditionTimedOut(message):
            "제한 시간 안에 조건을 만족하지 못했습니다: \(message)"
        case let .unavailable(message):
            "필요한 실행 환경을 사용할 수 없습니다: \(message)"
        case let .unexpected(message):
            "예상하지 못한 E2E 상태입니다: \(message)"
        }
    }
}

public struct E2EScenarioResult: Sendable {
    public let name: String
    public let duration: TimeInterval
    public let failure: String?

    public var passed: Bool { failure == nil }
}

public final class HangyeolE2ERunner {
    private let configuration: HangyeolE2EConfiguration
    private let driver = KeyEventDriver()
    private let accessibility = AccessibilityClient()
    private var installedIdentity: AppArtifactIdentity?
    private var originalInternalModeWasEnglish = false

    public init(configuration: HangyeolE2EConfiguration) {
        self.configuration = configuration
    }

    public func run() throws -> [E2EScenarioResult] {
        let inspected = try preflight()
        installedIdentity = inspected
        print("검증 앱: \(inspected)")
        print("손쉬운 사용: 허용됨")
        print("CGEvent 전송: 허용됨")

        guard !configuration.preflightOnly else { return [] }

        let inputSourceLease = try InputSourceLease.selectHangyeol()
        defer { inputSourceLease.restore() }
        print("입력 소스: \(inputSourceLease.currentDescription)")
        print("전환키: \(inputSourceLease.toggleBinding.displayName)")
        for identity in try runningInputMethodIdentities(
            matching: inspected
        ) {
            print("실행 중 입력기: \(identity)")
        }

        var results: [E2EScenarioResult?] = []
        let textEdit = try TextEditFixture.launch(
            driver: driver,
            accessibility: accessibility
        )
        var textEditIsClosed = false
        defer {
            if !textEditIsClosed { textEdit.close() }
        }
        results.append(runScenario("TextEdit 기본 두벌식 조합") {
            try self.verifyTextEditBasic(textEdit)
        })

        textEdit.close()
        textEditIsClosed = true

        // Finish TextEdit's complete window lifecycle before launching Chrome.
        // Closing TextEdit after Chrome is visible can race AppKit activation and
        // deliver the final Cmd+W to the newly frontmost browser window.
        let chrome: ChromeFixture
        do {
            chrome = try ChromeFixture.launch(
                chromeAppURL: configuration.chromeAppURL,
                accessibility: accessibility,
                driver: driver
            )
        } catch {
            restoreEnglishModeAfterChromeLaunchFailureIfNeeded()
            throw error
        }
        defer { chrome.close() }

        // macOS can restore a per-application input source when Chrome becomes
        // frontmost. Select Hangyeol once at the host boundary so the scenarios
        // below measure Hangyeol's own controller/session behavior rather than an
        // external ABC source remembered for Chrome.
        print("Chrome 활성 직후 입력 소스: \(inputSourceLease.currentDescription)")
        try inputSourceLease.selectHangyeolForActiveHost()
        print("Chrome E2E 입력 소스: \(inputSourceLease.currentDescription)")

        results.append(runChromeScenario(
            "Chrome input/contenteditable 두벌식 조합",
            chrome: chrome
        ) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromeBasic(chrome)
        })
        results.append(runChromeScenario("Chrome 중간 삽입·Backspace·전환", chrome: chrome) {
            try self.ensureKoreanMode(in: chrome, toggleBinding: inputSourceLease.toggleBinding)
            try self.verifyChromeMiddleEditing(chrome, binding: inputSourceLease.toggleBinding)
        })
        results.append(runChromeScenario("Chrome 한글 이모티콘 이름", chrome: chrome) {
            try self.ensureKoreanMode(in: chrome, toggleBinding: inputSourceLease.toggleBinding)
            try self.verifyChromeEmojiShortcode(chrome)
        })
        results.append(runChromeScenario("Chrome 클릭 field handoff", chrome: chrome) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromeClickHandoff(chrome)
        })
        results.append(runChromeScenario("Chrome 한영 전환 직후 첫 글자", chrome: chrome) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromeToggleFirstKey(
                chrome,
                binding: inputSourceLease.toggleBinding
            )
        })
        results.append(runChromeScenario("Chrome Tab 직후 첫 음절 handoff", chrome: chrome) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromeTabHandoff(chrome)
        })
        results.append(runChromeScenario("Chrome Tab 직후 연속 삭제·전환", chrome: chrome) {
            try self.ensureKoreanMode(in: chrome, toggleBinding: inputSourceLease.toggleBinding)
            try self.verifyChromeTabKeyOrder(chrome, binding: inputSourceLease.toggleBinding)
        })
        results.append(runChromeScenario("Chrome 붙여넣기 직후 한글", chrome: chrome) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromePasteThenHangul(chrome)
        })
        results.append(runChromeScenario("Chrome Shift+Return 조합 확정", chrome: chrome) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromeReturn(chrome)
        })
        results.append(runChromeScenario("Chrome Forward Delete 계약", chrome: chrome) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromeForwardDelete(chrome)
        })
        results.append(runChromeScenario("Chrome 브라우저 탭 직후 첫 음절", chrome: chrome) {
            try self.ensureKoreanMode(
                in: chrome,
                toggleBinding: inputSourceLease.toggleBinding
            )
            try self.verifyChromeBrowserTabHandoff(chrome)
        })

        if originalInternalModeWasEnglish {
            results.append(runChromeScenario("E2E 이전 영어 모드 복원", chrome: chrome) {
                try self.restoreEnglishMode(
                    in: chrome,
                    toggleBinding: inputSourceLease.toggleBinding
                )
            })
        }
        let executed = results.compactMap { $0 }
        if let filter = configuration.scenarioFilter,
           !executed.contains(where: { $0.name.contains(filter) }) {
            throw HangyeolE2EError.unavailable("일치하는 Chrome 시나리오 없음: \(filter)")
        }
        return executed
    }

    private func runningInputMethodIdentities(
        matching packaged: AppArtifactIdentity
    ) throws -> [RunningArtifactIdentity] {
        var applications: [NSRunningApplication] = []
        try Poll.wait(timeout: 5, description: "running Hangyeol IMK server") {
            applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: ProductIdentity.bundleID
            ).filter { !$0.isTerminated }
            return !applications.isEmpty
        }

        var identities: [RunningArtifactIdentity] = []
        var failures: [String] = []
        for application in applications {
            do {
                let identity = try ArtifactInspector.inspectRunningProcess(
                    pid: application.processIdentifier
                )
                identities.append(identity)
                failures.append(contentsOf: ArtifactInspector.compare(
                    running: identity,
                    packaged: packaged
                ).map { "pid \(identity.pid): \($0)" })
            } catch {
                failures.append(
                    "pid \(application.processIdentifier) 검사: \(error.localizedDescription)"
                )
            }
        }

        guard failures.isEmpty, !identities.isEmpty else {
            failures.append(
                "실행 중인 한결이 PKG와 일치하지 않습니다. "
                    + "~/Library/Logs/Hangyeol/installation.log와 "
                    + "input-source-activation-pending.plist를 확인하고, "
                    + "보류 상태라면 다시 로그인한 뒤 같은 PKG로 검증하세요."
            )
            throw HangyeolE2EError.preflight(failures)
        }
        return identities
    }

    private func preflight() throws -> AppArtifactIdentity {
        var failures: [String] = []
        let installed: AppArtifactIdentity
        do {
            installed = try ArtifactInspector.inspectApp(at: configuration.installedAppURL)
        } catch {
            failures.append("설치본 검사: \(error.localizedDescription)")
            throw HangyeolE2EError.preflight(failures)
        }
        if let packageURL = configuration.packageURL {
            do {
                let packaged = try ArtifactInspector.inspectPackage(at: packageURL)
                let comparison = ArtifactInspector.compare(installed: installed, packaged: packaged)
                failures.append(contentsOf: comparison.mismatches.map { "설치본/PKG 불일치: \($0)" })
                print("PKG 앱: \(packaged)")
            } catch {
                throw HangyeolE2EError.preflight(["PKG 검사: \(error.localizedDescription)"])
            }
        } else {
            print("패키지 생성 전 앱 검증: 실행 PID의 서명을 지정 앱과 대조합니다.")
        }
        if !AXIsProcessTrusted() {
            failures.append(
                "HangyeolE2E 실행 파일에 손쉬운 사용 권한이 없습니다. "
                    + "시스템 설정에서 직접 허용하거나, 폐기 가능한 Tart VM에서 권한을 준비하세요."
            )
        }
        if !CGPreflightPostEventAccess() {
            failures.append(
                "HangyeolE2E 실행 파일에 키 이벤트 전송 권한이 없습니다. "
                    + "TCC DB나 SIP는 변경하지 않습니다."
            )
        }
        if !FileManager.default.fileExists(atPath: configuration.chromeAppURL.path) {
            failures.append("Chrome 앱을 찾을 수 없습니다: \(configuration.chromeAppURL.path)")
        }
        if !InputSourceLease.isHangyeolAvailable() {
            failures.append("활성화 가능한 한결 입력 소스를 찾을 수 없습니다.")
        }
        guard failures.isEmpty else { throw HangyeolE2EError.preflight(failures) }
        return installed
    }

    private func runScenario(
        _ name: String,
        body: () throws -> Void
    ) -> E2EScenarioResult {
        let start = ContinuousClock.now
        do {
            try body()
            let duration = elapsedSeconds(since: start)
            print("PASS  \(name)  \(milliseconds(duration))")
            return E2EScenarioResult(name: name, duration: duration, failure: nil)
        } catch {
            let duration = elapsedSeconds(since: start)
            print("FAIL  \(name)  \(milliseconds(duration))")
            print("      \(error.localizedDescription)")
            return E2EScenarioResult(
                name: name,
                duration: duration,
                failure: error.localizedDescription
            )
        }
    }

    private func runChromeScenario(
        _ name: String,
        chrome: ChromeFixture,
        body: () throws -> Void
    ) -> E2EScenarioResult? {
        if let filter = configuration.scenarioFilter,
           !name.hasPrefix("E2E 이전"), !name.contains(filter) {
            return nil
        }
        let result = runScenario(name, body: body)
        if let failure = result.failure {
            printFailureDiagnostics(
                scenario: result.name,
                message: failure,
                chrome: chrome
            )
        }
        return result
    }

    private func elapsedSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func milliseconds(_ duration: TimeInterval) -> String {
        String(format: "%.1f ms", duration * 1_000)
    }

    private func verifyTextEditBasic(_ fixture: TextEditFixture) throws {
        try fixture.focus()
        driver.clearFocusedText()
        try accessibility.waitForFocusedValue(pid: fixture.pid, expected: "")

        driver.typePhysicalKeys("rk")
        let probe = try accessibility.waitForFocusedValue(
            pid: fixture.pid,
            matching: { $0 == "가" || $0 == "rk" },
            description: "TextEdit Korean-mode probe"
        )
        if probe == "rk" {
            originalInternalModeWasEnglish = true
            driver.perform(binding: fixture.toggleBinding)
            driver.clearFocusedText()
        } else {
            driver.clearFocusedText()
        }

        driver.typePhysicalKeys("gksrmf")
        driver.keyPair(.return)
        _ = try accessibility.waitForFocusedValue(
            pid: fixture.pid,
            matching: { ExactTextContract.matches($0, expected: "한글\n") },
            description: "TextEdit expected 한글 + Return"
        )
    }

    private func ensureKoreanMode(
        in chrome: ChromeFixture,
        toggleBinding: KeyBinding
    ) throws {
        func probe() throws -> String {
            try chrome.clear("normal-input")
            driver.typePhysicalKeys("rk")
            return try chrome.waitForState(
                description: "Korean-mode probe",
                where: {
                    $0.normalInput == "가" || $0.normalInput == "rk"
                }
            ).normalInput
        }

        // A newly focused Chromium client can briefly pass the first physical keys
        // through before its IMK controller is ready. A second probe distinguishes
        // that handoff race from a real Hangyeol English mode; toggling after only one
        // raw probe would invert an already-Korean session and hide the actual race.
        let firstProbe = try probe()
        let confirmedProbe = firstProbe == "rk" ? try probe() : firstProbe
        if confirmedProbe == "rk" {
            driver.perform(binding: toggleBinding)
            try chrome.clear("normal-input")
            driver.typePhysicalKeys("rk")
            _ = try chrome.waitForState(
                description: "Korean mode after toggle",
                where: { ExactTextContract.matches($0.normalInput, expected: "가") }
            )
        }
        try chrome.clear("normal-input")
    }

    private func restoreEnglishMode(
        in chrome: ChromeFixture,
        toggleBinding: KeyBinding
    ) throws {
        try chrome.clear("normal-input")
        driver.perform(binding: toggleBinding)
        driver.typePhysicalKeys("a")
        _ = try chrome.waitForState(
            description: "restore original English mode",
            where: { ExactTextContract.matches($0.normalInput, expected: "a") }
        )
        try chrome.clear("normal-input")
    }

    private func restoreEnglishMode(in textEdit: TextEditFixture) throws {
        try textEdit.focus()
        driver.perform(binding: textEdit.toggleBinding)
        driver.clearFocusedText()
        driver.typePhysicalKeys("a")
        _ = try accessibility.waitForFocusedValue(
            pid: textEdit.pid,
            matching: { ExactTextContract.matches($0, expected: "a") },
            description: "restore original TextEdit English mode"
        )
        driver.clearFocusedText()
    }

    private func restoreEnglishModeAfterChromeLaunchFailureIfNeeded() {
        guard originalInternalModeWasEnglish,
              let recovery = try? TextEditFixture.launch(
                driver: driver,
                accessibility: accessibility
              ) else { return }
        defer { recovery.close() }
        try? restoreEnglishMode(in: recovery)
    }

    private func verifyChromeBasic(_ chrome: ChromeFixture) throws {
        try chrome.clear("normal-input")
        try chrome.clear("editable")
        try chrome.click("normal-input")
        driver.typePhysicalKeys("gksrmf")
        _ = try chrome.waitForState(
            description: "normal input=한글",
            where: { ExactTextContract.matches($0.normalInput, expected: "한글") }
        )
        try chrome.click("editable")
        driver.typePhysicalKeys("enqjftlr")
        _ = try chrome.waitForState(
            description: "contenteditable=두벌식",
            where: {
                ExactTextContract.matches($0.normalInput, expected: "한글")
                    && ExactTextContract.matches($0.editable, expected: "두벌식")
            }
        )
    }

    private func verifyChromeClickHandoff(_ chrome: ChromeFixture) throws {
        for iteration in 1...3 {
            try chrome.clear("left")
            try chrome.clear("right")
            try chrome.click("left")
            driver.typePhysicalKeys("sk")
            try chrome.click("right")
            driver.typePhysicalKeys("sk")
            _ = try chrome.waitForState(
                description: "click handoff iteration \(iteration)",
                where: {
                    ExactTextContract.matches($0.left, expected: "나")
                        && ExactTextContract.matches($0.right, expected: "나")
                }
            )
        }
    }

    private func verifyChromeToggleFirstKey(
        _ chrome: ChromeFixture,
        binding: KeyBinding
    ) throws {
        try chrome.clear("normal-input")
        try chrome.click("normal-input")
        driver.perform(binding: binding)
        driver.typePhysicalKeys("a")
        _ = try chrome.waitForState(
            description: "한→영 전환 직후 첫 글자",
            where: { ExactTextContract.matches($0.normalInput, expected: "a") }
        )
        driver.perform(binding: binding)
        driver.typePhysicalKeys("sk")
        _ = try chrome.waitForState(
            description: "영→한 전환 직후 첫 글자",
            where: { ExactTextContract.matches($0.normalInput, expected: "a나") }
        )
    }

    private func verifyChromeTabHandoff(_ chrome: ChromeFixture) throws {
        for iteration in 1...10 {
            try chrome.clear("left")
            try chrome.clear("right")
            try chrome.click("left")
            driver.typePhysicalKeys("sk")
            driver.keyPair(.tab)
            // Deliberately do not poll DOM focus here. Real typing can beat the late
            // same-client activateServer callback, which is the regression boundary.
            driver.typePhysicalKeys("rP")
            _ = try chrome.waitForState(
                description: "immediate Tab handoff iteration \(iteration)",
                where: {
                    ExactTextContract.matches($0.left, expected: "나")
                        && ExactTextContract.matches($0.right, expected: "계")
                        && $0.focusedID == "right"
                }
            )
        }
    }

    private func verifyChromeTabKeyOrder(_ chrome: ChromeFixture, binding: KeyBinding) throws {
        for iteration in 1...5 {
            try chrome.clear("left")
            try chrome.clear("right")
            try chrome.click("left")
            driver.typePhysicalKeys("sk")
            driver.keyPair(.tab)
            driver.typePhysicalKeys("sk")
            driver.keyPair(.backspace)
            driver.keyPair(.backspace)
            driver.typePhysicalKeys("sk")
            driver.perform(binding: binding)
            driver.typePhysicalKeys("a")
            driver.keyPair(.backspace)
            driver.perform(binding: binding)
            driver.typePhysicalKeys("rk")
            _ = try chrome.waitForState(description: "Tab deletion and toggle order \(iteration)") {
                ExactTextContract.matches($0.left, expected: "나")
                    && ExactTextContract.matches($0.right, expected: "나가")
            }
            try chrome.clear("left")
            try chrome.clear("right")
            try chrome.click("left")
            driver.perform(binding: binding)
            driver.keyPair(.tab)
            driver.typePhysicalKeys("aaa")
            driver.keyPair(.backspace)
            driver.keyPair(.return)
            driver.perform(binding: binding)
            driver.typePhysicalKeys("sk")
            _ = try chrome.waitForState(description: "Tab English host actions \(iteration)") {
                ExactTextContract.matches($0.left, expected: "")
                    && ExactTextContract.matches($0.right, expected: "aa나")
            }
        }
    }

    private func verifyChromePasteThenHangul(_ chrome: ChromeFixture) throws {
        try chrome.clear("normal-input")
        try chrome.click("normal-input")
        let clipboard = ClipboardLease()
        defer { clipboard.restore() }
        clipboard.replace(with: "seed:")
        driver.keyPair(.v, flags: .maskCommand)
        driver.typePhysicalKeys("sk")
        _ = try chrome.waitForState(
            description: "paste then Korean",
            where: { ExactTextContract.matches($0.normalInput, expected: "seed:나") }
        )
    }

    private func verifyChromeReturn(_ chrome: ChromeFixture) throws {
        try chrome.clear("multiline")
        try chrome.click("multiline")
        driver.typePhysicalKeys("gksrmf")
        _ = try chrome.waitForState(description: "한글 before Shift+Return") {
            ExactTextContract.matches($0.multiline, expected: "한글")
        }
        driver.physicalChord(.return, flags: .maskShift)
        _ = try chrome.waitForState(description: "한글 Shift+Return retains 글") {
            ExactTextContract.matches($0.multiline, expected: "한글\n")
        }
        try chrome.clear("editable")
        try chrome.click("editable")
        driver.typePhysicalKeys("Eodp")
        driver.physicalChord(.return, flags: .maskShift)
        driver.typePhysicalKeys("sk")
        _ = try chrome.waitForState(
            description: "contenteditable 때에 Shift+Return preserves 에 and one newline",
            where: { ExactTextContract.matches($0.editable, expected: "때에\n나") }
        )
        try chrome.clear("multiline")
        try chrome.click("multiline")
        driver.typePhysicalKeys("Eodp")
        driver.physicalChord(.return, flags: .maskShift)
        _ = try chrome.waitForState(
            description: "때에 Shift+Return preserves 에",
            where: { ExactTextContract.matches($0.multiline, expected: "때에\n") }
        )
        try chrome.clear("multiline")
        try chrome.click("multiline")
        driver.typePhysicalKeys("dlqfur")
        driver.keyPair(.return, flags: .maskShift)
        _ = try chrome.waitForState(
            description: "Shift+Return keeps 력 and inserts one line break",
            where: { ExactTextContract.matches($0.multiline, expected: "입력\n") }
        )
        driver.typePhysicalKeys("sk")
        _ = try chrome.waitForState(
            description: "Korean input after Shift+Return replay",
            where: { ExactTextContract.matches($0.multiline, expected: "입력\n나") }
        )
    }

    private func verifyChromeMiddleEditing(_ chrome: ChromeFixture, binding: KeyBinding) throws {
        for field in ["normal-input", "editable"] {
            try chrome.clear(field)
            driver.typePhysicalKeys("rkskekfk")
            driver.keyPair(.leftArrow)
            driver.keyPair(.leftArrow)
            driver.typePhysicalKeys("akfr")
            driver.keyPair(.backspace) // 맑 -> 말; surrounding 가나다라 must survive.
            driver.perform(binding: binding)
            driver.typePhysicalKeys("x")
            driver.perform(binding: binding)
            driver.typePhysicalKeys("sk")
            driver.keyPair(CGKeyCode(124)) // Right Arrow: commit without adding a character
            _ = try chrome.waitForState(
                description: "\(field): 가나말x나다라 after middle editing and two mode switches",
                where: { ExactTextContract.matches(
                    field == "editable" ? $0.editable : $0.normalInput,
                    expected: "가나말x나다라"
                ) }
            )
        }
    }

    private func verifyChromeEmojiShortcode(_ chrome: ChromeFixture) throws {
        for field in ["normal-input", "editable"] {
            try chrome.clear(field)
            driver.physicalChord(CGKeyCode(41), flags: .maskShift) // :
            driver.typePhysicalKeys("dhksfy") // 완료
            driver.physicalChord(CGKeyCode(41), flags: .maskShift)
            _ = try chrome.waitForState(
                description: "\(field): exact NFC :완료:",
                where: { ExactTextContract.matches(
                    field == "editable" ? $0.editable : $0.normalInput,
                    expected: ":완료:"
                ) }
            )
        }
    }

    private func verifyChromeForwardDelete(_ chrome: ChromeFixture) throws {
        for field in ["normal-input", "editable"] {
            try chrome.clear(field)
            try chrome.click(field)
            driver.typePhysicalKeys("gksk")
            // No DOM wait before Delete: protect the last actively composing 나.
            driver.keyPair(.forwardDelete)
            _ = try chrome.waitForState(description: "하나| fast Forward Delete must keep 하나") {
                ExactTextContract.matches(field == "editable" ? $0.editable : $0.normalInput,
                                          expected: "하나")
            }
        }
        for field in ["normal-input", "editable"] {
            try chrome.clear(field)
            try chrome.click(field)
            driver.typePhysicalKeys("gksrmf")
            driver.keyPair(.leftArrow)
            driver.typePhysicalKeys("wnd")
            _ = try chrome.waitForState(description: "한중|글 before Forward Delete") {
                ExactTextContract.matches(field == "editable" ? $0.editable : $0.normalInput,
                                          expected: "한중글")
            }
            driver.keyPair(.forwardDelete)
            _ = try chrome.waitForState(description: "한중|글 Forward Delete must retain 중") {
                ExactTextContract.matches(field == "editable" ? $0.editable : $0.normalInput,
                                          expected: "한중")
            }
        }
        try chrome.clear("editable")
        try chrome.click("editable")
        driver.typePhysicalKeys("Eodp")
        driver.keyPair(.leftArrow)
        driver.typePhysicalKeys("dl")
        driver.keyPair(.forwardDelete)
        _ = try chrome.waitForState(
            description: "contenteditable 때이|에 Forward Delete preserves 이 and deletes 에",
            where: { ExactTextContract.matches($0.editable, expected: "때이") }
        )
        try chrome.clear("normal-input")
        try chrome.click("normal-input")
        driver.typePhysicalKeys("Eodp")
        driver.keyPair(.leftArrow)
        driver.typePhysicalKeys("dl")
        driver.keyPair(.forwardDelete)
        _ = try chrome.waitForState(
            description: "때이|에 Forward Delete preserves 이 and deletes 에",
            where: { ExactTextContract.matches($0.normalInput, expected: "때이") }
        )
        try chrome.clear("normal-input")
        try chrome.click("normal-input")
        driver.typePhysicalKeys("rkskekfk")
        driver.keyPair(.leftArrow)
        driver.keyPair(.leftArrow)
        driver.typePhysicalKeys("ak")
        driver.keyPair(.forwardDelete)
        _ = try chrome.waitForState(
            description: "가나마라 after immediate Forward Delete",
            where: { ExactTextContract.matches($0.normalInput, expected: "가나마라") }
        )

        try chrome.clear("normal-input")
        driver.typePhysicalKeys("rkskekfk")
        driver.keyPair(.leftArrow)
        driver.keyPair(.leftArrow)
        driver.typePhysicalKeys("akfr")
        driver.keyPair(.backspace)
        driver.keyPair(.forwardDelete)
        _ = try chrome.waitForState(
            description: "맑 Backspace 뒤 Forward Delete keeps 말 and deletes 다",
            where: { ExactTextContract.matches($0.normalInput, expected: "가나말라") }
        )
    }

    private func verifyChromeBrowserTabHandoff(_ chrome: ChromeFixture) throws {
        try chrome.clear("normal-input")
        try chrome.click("normal-input")
        driver.typePhysicalKeys("sk")
        _ = try chrome.waitForState(
            description: "첫 Chrome 탭의 나",
            where: {
                $0.pageID.isEmpty
                    && ExactTextContract.matches($0.normalInput, expected: "나")
            }
        )

        let secondPageID = "handoff-\(UUID().uuidString)"
        try chrome.openDuplicateTab(pageID: secondPageID)
        try chrome.click("normal-input")
        driver.typePhysicalKeys("sk")
        _ = try chrome.waitForState(
            description: "두 번째 Chrome 탭의 나",
            where: {
                $0.pageID == secondPageID
                    && ExactTextContract.matches($0.normalInput, expected: "나")
            }
        )

        var firstPageSuffixCount = 0
        var secondPageSuffixCount = 0
        for iteration in 1...10 {
            driver.keyPair(.tab, flags: .maskControl)
            // Do not wait for DOM/AX focus: this is the real handoff boundary where
            // Blink can reactivate after the first jamo reached the selected tab.
            driver.typePhysicalKeys("rP")

            let expectsFirstPage = !iteration.isMultiple(of: 2)
            if expectsFirstPage {
                firstPageSuffixCount += 1
            } else {
                secondPageSuffixCount += 1
            }
            let expectedPageID = expectsFirstPage ? "" : secondPageID
            let suffixCount = expectsFirstPage
                ? firstPageSuffixCount
                : secondPageSuffixCount
            let expectedText = "나" + String(repeating: "계", count: suffixCount)
            _ = try chrome.waitForState(
                description: "Chrome 탭 즉시 입력 iteration \(iteration)",
                where: {
                    $0.pageID == expectedPageID
                        && ExactTextContract.matches($0.normalInput, expected: expectedText)
                }
            )
        }
    }

    private func printFailureDiagnostics(
        scenario: String,
        message: String,
        chrome: ChromeFixture
    ) {
        print("\n--- 실패 진단: \(scenario) ---")
        print("오류: \(message)")
        if let installedIdentity { print("설치 버전: \(installedIdentity)") }
        let frontmost = NSWorkspace.shared.frontmostApplication
        print(
            "활성 앱: \(frontmost?.localizedName ?? "<없음>") "
                + "(\(frontmost?.bundleIdentifier ?? "<알 수 없음>"))"
        )
        print("활성 필드: \(accessibility.focusedElementDescription(pid: chrome.pid))")
        if let state = chrome.currentState() {
            print("fixture state: \(state)")
            print("normal unicode: \(ExactTextContract.unicodeDescription(state.normalInput))")
            print("left unicode: \(ExactTextContract.unicodeDescription(state.left))")
            print("right unicode: \(ExactTextContract.unicodeDescription(state.right))")
            print("multiline unicode: \(ExactTextContract.unicodeDescription(state.multiline))")
        } else {
            print("fixture state: <읽기 실패>")
        }
    }
}

private final class InputSourceLease {
    let toggleBinding: KeyBinding
    private let previousSource: TISInputSource
    private let previousInputModeID: String?
    private var restored = false

    var currentDescription: String {
        Self.currentInputSourceDescription()
    }

    private init(previousSource: TISInputSource, toggleBinding: KeyBinding) {
        self.previousSource = previousSource
        self.previousInputModeID = Self.inputModeID(for: previousSource)
        self.toggleBinding = toggleBinding
    }

    static func isHangyeolAvailable() -> Bool {
        hangyeolSource() != nil
    }

    static func selectHangyeol() throws -> InputSourceLease {
        guard let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            throw HangyeolE2EError.unavailable("현재 입력 소스를 읽을 수 없습니다.")
        }
        guard let hangyeol = hangyeolSource() else {
            throw HangyeolE2EError.unavailable("한결 입력 소스가 등록되어 있지 않습니다.")
        }
        try selectIfNeeded(hangyeol, description: "한결 입력 소스 선택")
        return InputSourceLease(
            previousSource: previous,
            toggleBinding: loadInstalledToggleBinding()
        )
    }

    func selectHangyeolForActiveHost() throws {
        guard let hangyeol = Self.hangyeolSource() else {
            throw HangyeolE2EError.unavailable("Chrome에서 선택할 한결 입력 소스가 없습니다.")
        }
        try Self.selectIfNeeded(
            hangyeol,
            description: "Chrome의 한결 입력 소스 선택"
        )
    }

    private static func selectIfNeeded(
        _ hangyeol: TISInputSource,
        description: String
    ) throws {
        guard currentInputModeID() != ProductIdentity.inputModeID else { return }
        let status = TISSelectInputSource(hangyeol)
        guard status == noErr else {
            throw HangyeolE2EError.unexpected("TISSelectInputSource status=\(status)")
        }
        try Poll.wait(timeout: 5, description: description) {
            Self.currentInputModeID() == ProductIdentity.inputModeID
        }
    }

    func restore() {
        guard !restored else { return }
        restored = true
        guard Self.currentInputModeID() != previousInputModeID else { return }
        _ = TISSelectInputSource(previousSource)
    }

    deinit { restore() }

    private static func hangyeolSource() -> TISInputSource? {
        let filter: [String: Any] = [
            kTISPropertyBundleID as String: ProductIdentity.bundleID,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let sources = TISCreateInputSourceList(
            filter as CFDictionary,
            false
        )?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return sources.first {
            stringProperty(kTISPropertyInputModeID, source: $0) == ProductIdentity.inputModeID
                || stringProperty(kTISPropertyInputSourceID, source: $0)
                    == ProductIdentity.inputModeID
        }
    }

    private static func currentInputModeID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return inputModeID(for: source)
    }

    private static func inputModeID(for source: TISInputSource) -> String? {
        return stringProperty(kTISPropertyInputModeID, source: source)
            ?? stringProperty(kTISPropertyInputSourceID, source: source)
    }

    private static func currentInputSourceDescription() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return "<알 수 없음>"
        }
        let name = stringProperty(kTISPropertyLocalizedName, source: source) ?? "<이름 없음>"
        return "\(name) [\(currentInputModeID() ?? "<ID 없음>")]"
    }

    private static func stringProperty(
        _ key: CFString,
        source: TISInputSource
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func loadInstalledToggleBinding() -> KeyBinding {
        let key = "\(ProductIdentity.preferencePrefix).toggleKeyBinding"
        let domain = UserDefaults.standard.persistentDomain(forName: ProductIdentity.bundleID)
        if let data = domain?[key] as? Data,
           let binding = try? JSONDecoder().decode(KeyBinding.self, from: data),
           binding.keyCode != 57,
           binding.keyCode != 63 {
            return binding
        }
        return .defaultToggle
    }
}

private enum PhysicalKey: CGKeyCode {
    case a = 0
    case v = 9
    case tab = 48
    case space = 49
    case backspace = 51
    case rightCommand = 54
    case returnKey = 36
    case leftArrow = 123
    case forwardDelete = 117

    static var `return`: PhysicalKey { .returnKey }
}

struct E2EPhysicalModifierPlan {
    struct Press {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    let baseFlags: CGEventFlags
    let presses: [Press]

    var effectiveFlags: CGEventFlags {
        CGEventFlags(rawValue: presses.reduce(baseFlags.rawValue) {
            $0 | $1.flags.rawValue
        })
    }

    static func make(for flags: CGEventFlags) -> E2EPhysicalModifierPlan {
        let rawValue = flags.rawValue
        let families: [(
            aggregate: CGEventFlags,
            leftSide: UInt64,
            rightSide: UInt64,
            leftKeyCode: CGKeyCode,
            rightKeyCode: CGKeyCode
        )] = [
            (.maskControl, UInt64(NX_DEVICELCTLKEYMASK), UInt64(NX_DEVICERCTLKEYMASK), 59, 62),
            (.maskAlternate, UInt64(NX_DEVICELALTKEYMASK), UInt64(NX_DEVICERALTKEYMASK), 58, 61),
            (.maskShift, UInt64(NX_DEVICELSHIFTKEYMASK), UInt64(NX_DEVICERSHIFTKEYMASK), 56, 60),
            (.maskCommand, UInt64(NX_DEVICELCMDKEYMASK), UInt64(NX_DEVICERCMDKEYMASK), 55, 54),
        ]
        let trackedMask = families.reduce(UInt64(0)) {
            $0 | $1.aggregate.rawValue | $1.leftSide | $1.rightSide
        }
        let presses = families.compactMap { family -> Press? in
            guard rawValue & (family.aggregate.rawValue | family.leftSide | family.rightSide) != 0 else {
                return nil
            }
            let usesRightSide = rawValue & family.rightSide != 0
            let keyCode = usesRightSide ? family.rightKeyCode : family.leftKeyCode
            let sideFlag = usesRightSide ? family.rightSide : family.leftSide
            return Press(
                keyCode: keyCode,
                flags: CGEventFlags(rawValue: family.aggregate.rawValue | sideFlag)
            )
        }
        return E2EPhysicalModifierPlan(
            baseFlags: CGEventFlags(rawValue: rawValue & ~trackedMask),
            presses: presses
        )
    }
}

private final class KeyEventDriver {
    private let eventSource = CGEventSource(stateID: .combinedSessionState)

    private static let qwertyCodes: [Character: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04,
        "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F,
        "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D,
        "m": 0x2E
    ]

    func typePhysicalKeys(_ keys: String) {
        for character in keys {
            let normalized = Character(String(character).lowercased())
            guard let keyCode = Self.qwertyCodes[normalized] else {
                preconditionFailure("E2E key mapping missing: \(character)")
            }
            keyPair(keyCode, flags: character.isUppercase ? .maskShift : [])
        }
    }

    func keyPair(_ key: PhysicalKey, flags: CGEventFlags = []) {
        keyPair(key.rawValue, flags: flags)
    }

    func keyPair(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        if !flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate]).isEmpty {
            physicalChord(keyCode, flags: flags)
            return
        }
        postKeyboard(keyCode: keyCode, keyDown: true, flags: flags)
        Thread.sleep(forTimeInterval: 0.002)
        postKeyboard(keyCode: keyCode, keyDown: false, flags: flags)
        Thread.sleep(forTimeInterval: 0.005)
    }

    func physicalChord(_ key: PhysicalKey, flags: CGEventFlags) {
        physicalChord(key.rawValue, flags: flags)
    }

    func physicalChord(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let modifierPlan = E2EPhysicalModifierPlan.make(for: flags)
        var activeModifierFlags = modifierPlan.baseFlags
        for press in modifierPlan.presses {
            activeModifierFlags = CGEventFlags(
                rawValue: activeModifierFlags.rawValue | press.flags.rawValue
            )
            postFlagsChanged(
                keyCode: press.keyCode,
                keyDown: true,
                flags: activeModifierFlags
            )
            Thread.sleep(forTimeInterval: 0.002)
        }

        postKeyboard(
            keyCode: keyCode,
            keyDown: true,
            flags: modifierPlan.effectiveFlags
        )
        Thread.sleep(forTimeInterval: 0.002)
        postKeyboard(
            keyCode: keyCode,
            keyDown: false,
            flags: modifierPlan.effectiveFlags
        )

        for press in modifierPlan.presses.reversed() {
            activeModifierFlags = CGEventFlags(
                rawValue: activeModifierFlags.rawValue & ~press.flags.rawValue
            )
            postFlagsChanged(
                keyCode: press.keyCode,
                keyDown: false,
                flags: activeModifierFlags
            )
            Thread.sleep(forTimeInterval: 0.002)
        }
        Thread.sleep(forTimeInterval: 0.005)
    }

    func clearFocusedText() {
        keyPair(PhysicalKey.a.rawValue, flags: .maskCommand)
        keyPair(.backspace)
    }

    func perform(binding: KeyBinding) {
        let keyCode = CGKeyCode(binding.keyCode)
        if binding.isModifierOnly, binding.isModifierKey {
            let flags = modifierFlag(for: keyCode)
            postFlagsChanged(keyCode: keyCode, keyDown: true, flags: flags)
            Thread.sleep(forTimeInterval: 0.002)
            postFlagsChanged(keyCode: keyCode, keyDown: false, flags: [])
            Thread.sleep(forTimeInterval: 0.005)
            return
        }
        keyPair(keyCode, flags: CGEventFlags(rawValue: binding.modifiers))
    }

    func click(_ point: CGPoint) {
        guard let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.001)
        up.post(tap: .cghidEventTap)
    }

    private func postKeyboard(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags
    ) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postFlagsChanged(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags
    ) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags {
        switch keyCode {
        case 54:
            CGEventFlags(rawValue:
                CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICERCMDKEYMASK)
            )
        case 55:
            CGEventFlags(rawValue:
                CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICELCMDKEYMASK)
            )
        case 58:
            CGEventFlags(rawValue:
                CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
            )
        case 61:
            CGEventFlags(rawValue:
                CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK)
            )
        case 59:
            CGEventFlags(rawValue:
                CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)
            )
        case 62:
            CGEventFlags(rawValue:
                CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICERCTLKEYMASK)
            )
        case 56:
            CGEventFlags(rawValue:
                CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICELSHIFTKEYMASK)
            )
        case 60:
            CGEventFlags(rawValue:
                CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICERSHIFTKEYMASK)
            )
        default: []
        }
    }
}

private final class AccessibilityClient {
    func waitForFocusedValue(pid: pid_t, expected: String) throws {
        _ = try waitForFocusedValue(
            pid: pid,
            matching: { ExactTextContract.matches($0, expected: expected) },
            description: "focused value=\(expected)"
        )
    }

    func waitForFocusedValue(
        pid: pid_t,
        matching predicate: @escaping (String) -> Bool,
        description: String
    ) throws -> String {
        var latest: String?
        do {
            try Poll.wait(timeout: 5, description: description) {
                latest = self.focusedValue(pid: pid)
                return latest.map(predicate) == true
            }
        } catch {
            throw HangyeolE2EError.unexpected(
                "\(description); actual=\(ExactTextContract.unicodeDescription(latest ?? "<nil>"))"
            )
        }
        return latest ?? ""
    }

    func focusedValue(pid: pid_t) -> String? {
        guard let element = focusedElement(pid: pid) else { return nil }
        return stringAttribute(element, kAXValueAttribute)
    }

    func focusedElementIsOutsideWebContent(pid: pid_t) -> Bool {
        guard let element = focusedElement(pid: pid) else { return false }
        return stringAttribute(element, kAXDOMIdentifierAttribute) == nil
    }

    func fixtureState(pid: pid_t) -> ChromeFixtureState? {
        for title in windowTitles(pid: pid) {
            if let state = FixtureStateCodec.decode(windowTitle: title) {
                return state
            }
        }
        return nil
    }

    func centerOfElement(pid: pid_t, domID: String) -> CGPoint? {
        guard let element = findElement(pid: pid, domID: domID),
              let position = pointAttribute(element, kAXPositionAttribute),
              let size = sizeAttribute(element, kAXSizeAttribute) else {
            return nil
        }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    func focusedElementDescription(pid: pid_t) -> String {
        guard let element = focusedElement(pid: pid) else { return "<읽기 실패>" }
        let role = stringAttribute(element, kAXRoleAttribute) ?? "<role 없음>"
        let domID = stringAttribute(element, kAXDOMIdentifierAttribute) ?? "<DOM ID 없음>"
        let identifier = stringAttribute(element, kAXIdentifierAttribute) ?? "<identifier 없음>"
        let value = stringAttribute(element, kAXValueAttribute) ?? "<value 없음>"
        return "role=\(role), domID=\(domID), identifier=\(identifier), value=\(value)"
    }

    func enableChromeAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(
            app,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            app,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.compactMap { stringAttribute($0, kAXTitleAttribute) }
    }

    private func findElement(pid: pid_t, domID: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var inspected = 0
        while !queue.isEmpty, inspected < 6_000 {
            let (element, depth) = queue.removeFirst()
            inspected += 1
            if stringAttribute(element, kAXDOMIdentifierAttribute) == domID
                || stringAttribute(element, kAXIdentifierAttribute) == domID {
                return element
            }
            guard depth < 24 else { continue }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    private func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        attribute(element, key) as? String
    }

    private func pointAttribute(_ element: AXUIElement, _ key: String) -> CGPoint? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ key: String) -> CGSize? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}

private final class ChromeFixture {
    let pid: pid_t
    private let process: Process
    private let profileURL: URL
    private let fixtureURL: URL
    private let accessibility: AccessibilityClient
    private let driver: KeyEventDriver
    private var closed = false

    private init(
        pid: pid_t,
        process: Process,
        profileURL: URL,
        fixtureURL: URL,
        accessibility: AccessibilityClient,
        driver: KeyEventDriver
    ) {
        self.pid = pid
        self.process = process
        self.profileURL = profileURL
        self.fixtureURL = fixtureURL
        self.accessibility = accessibility
        self.driver = driver
    }

    static func launch(
        chromeAppURL: URL,
        accessibility: AccessibilityClient,
        driver: KeyEventDriver
    ) throws -> ChromeFixture {
        guard let fixtureURL = Bundle.module.url(
            forResource: "chrome-fixture",
            withExtension: "html"
        ) else {
            throw HangyeolE2EError.unavailable("Chrome fixture resource")
        }
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hangyeol-e2e-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profileURL,
            withIntermediateDirectories: true
        )
        let executableURL = chromeAppURL
            .appendingPathComponent("Contents/MacOS/Google Chrome")
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--user-data-dir=\(profileURL.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-component-update",
            "--disable-sync",
            "--new-window",
            fixtureURL.absoluteString
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: profileURL)
            throw error
        }
        let fixture = ChromeFixture(
            pid: process.processIdentifier,
            process: process,
            profileURL: profileURL,
            fixtureURL: fixtureURL,
            accessibility: accessibility,
            driver: driver
        )
        accessibility.enableChromeAccessibility(pid: fixture.pid)
        try Poll.wait(timeout: 15, description: "Chrome local fixture load") {
            accessibility.fixtureState(pid: fixture.pid) != nil
        }
        return fixture
    }

    func openDuplicateTab(pageID: String) throws {
        try activate()
        let clipboard = ClipboardLease()
        defer { clipboard.restore() }
        var components = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false)
        components?.fragment = pageID
        guard let tabURL = components?.url else {
            throw HangyeolE2EError.unexpected("Chrome fixture tab URL 생성 실패")
        }

        clipboard.replace(with: tabURL.absoluteString)
        driver.physicalChord(17, flags: .maskCommand) // Cmd+T: create the second tab.
        driver.physicalChord(37, flags: .maskCommand)
        // AX focus may retain the previous web element during native-toolbar
        // navigation. The unique page ID below verifies the actual loaded tab.
        driver.physicalChord(.v, flags: .maskCommand)
        driver.keyPair(.return)
        _ = try waitForState(description: "duplicate Chrome fixture tab load") {
            $0.pageID == pageID
        }
    }

    func clear(_ domID: String) throws {
        for _ in 0..<3 {
            try click(domID)
            driver.physicalChord(PhysicalKey.a.rawValue, flags: .maskCommand)
            do {
                _ = try waitForState(timeout: 0.75, description: "select all \(domID)") { state in
                    let selection = state.selections[domID]
                    return selection?.start == 0 && selection?.end == self.value(for: domID, in: state).utf16.count
                }
                driver.keyPair(.backspace)
                _ = try waitForState(
                    timeout: 0.75,
                    description: "clear \(domID)"
                ) { state in
                    self.value(for: domID, in: state).isEmpty
                }
                return
            } catch {
                continue
            }
        }
        let actual = currentState().map { value(for: domID, in: $0) } ?? "<state unavailable>"
        throw HangyeolE2EError.unexpected(
            "clear \(domID); actual=\(ExactTextContract.unicodeDescription(actual))"
        )
    }

    func click(_ domID: String) throws {
        try activate()
        var latest: ChromeFixtureState?
        for _ in 0..<3 {
            var center: CGPoint?
            try Poll.wait(timeout: 5, description: "click target \(domID)") {
                center = self.accessibility.centerOfElement(pid: self.pid, domID: domID)
                if center == nil, let fixturePoint = self.currentState()?.centers[domID] {
                    center = CGPoint(x: fixturePoint.x, y: fixturePoint.y)
                }
                return center != nil
            }
            guard let center else {
                throw HangyeolE2EError.unavailable("AX center for \(domID)")
            }
            driver.click(center)
            do {
                try Poll.wait(timeout: 0.75, description: "focus \(domID)") {
                    latest = self.currentState()
                    return latest?.focusedID == domID
                }
                return
            } catch {
                continue
            }
        }
        throw HangyeolE2EError.unexpected(
            "focus \(domID); actual=\(String(describing: latest))"
        )
    }

    private func activate() throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw HangyeolE2EError.unavailable("Chrome fixture process \(pid)")
        }
        app.activate()
        try Poll.wait(timeout: 5, description: "Chrome fixture frontmost") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid
        }
    }

    func waitForState(
        timeout: TimeInterval = 5,
        description: String,
        where predicate: @escaping (ChromeFixtureState) -> Bool
    ) throws -> ChromeFixtureState {
        var latest: ChromeFixtureState?
        do {
            try Poll.wait(timeout: timeout, description: description) {
                latest = self.currentState()
                return latest.map(predicate) == true
            }
        } catch {
            throw HangyeolE2EError.unexpected(
                "\(description); actual=\(String(describing: latest))"
            )
        }
        guard let latest else {
            throw HangyeolE2EError.conditionTimedOut(description)
        }
        return latest
    }

    func currentState() -> ChromeFixtureState? {
        accessibility.fixtureState(pid: pid)
    }

    func close() {
        guard !closed else { return }
        closed = true
        process.terminate()
        _ = try? Poll.wait(timeout: 5, description: "Chrome fixture shutdown") {
            !process.isRunning
        }
        if !process.isRunning {
            try? FileManager.default.removeItem(at: profileURL)
        } else {
            print("경고: Chrome fixture가 종료되지 않아 profile을 남깁니다: \(profileURL.path)")
        }
    }

    deinit { close() }

    private func value(for domID: String, in state: ChromeFixtureState) -> String {
        switch domID {
        case "normal-input": state.normalInput
        case "editable": state.editable
        case "left": state.left
        case "right": state.right
        case "multiline": state.multiline
        default: "<unknown>"
        }
    }
}

struct TextEditFixtureLaunchPolicy {
    static let bundleIdentifier = "com.apple.TextEdit"

    static func makeConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        return configuration
    }
}

private final class WorkspaceOpenResult: @unchecked Sendable {
    private let lock = NSLock()
    private var application: NSRunningApplication?
    private var error: Error?
    private var completed = false

    func finish(application: NSRunningApplication?, error: Error?) {
        lock.withLock {
            self.application = application
            self.error = error
            completed = true
        }
    }

    func snapshot() -> (
        completed: Bool,
        application: NSRunningApplication?,
        error: Error?
    ) {
        lock.withLock { (completed, application, error) }
    }
}

private final class TextEditFixture {
    let pid: pid_t
    let toggleBinding: KeyBinding
    private let app: NSRunningApplication
    private let fileURL: URL
    private let driver: KeyEventDriver
    private let accessibility: AccessibilityClient
    private var closed = false

    private init(
        pid: pid_t,
        toggleBinding: KeyBinding,
        app: NSRunningApplication,
        fileURL: URL,
        driver: KeyEventDriver,
        accessibility: AccessibilityClient
    ) {
        self.pid = pid
        self.toggleBinding = toggleBinding
        self.app = app
        self.fileURL = fileURL
        self.driver = driver
        self.accessibility = accessibility
    }

    static func launch(
        driver: KeyEventDriver,
        accessibility: AccessibilityClient
    ) throws -> TextEditFixture {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hangyeol-e2e-\(UUID().uuidString).txt")
        try Data().write(to: fileURL, options: .atomic)

        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: TextEditFixtureLaunchPolicy.bundleIdentifier
        ) else {
            throw HangyeolE2EError.unavailable("TextEdit application")
        }
        let openResult = WorkspaceOpenResult()
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: applicationURL,
            configuration: TextEditFixtureLaunchPolicy.makeConfiguration()
        ) { application, error in
            openResult.finish(application: application, error: error)
        }
        try Poll.wait(timeout: 10, description: "isolated TextEdit launch") {
            openResult.snapshot().completed
        }
        let result = openResult.snapshot()
        if let error = result.error {
            try? FileManager.default.removeItem(at: fileURL)
            throw HangyeolE2EError.unavailable(
                "TextEdit launch: \(error.localizedDescription)"
            )
        }
        guard let app = result.application else {
            try? FileManager.default.removeItem(at: fileURL)
            throw HangyeolE2EError.unavailable("TextEdit process")
        }
        let fixture = TextEditFixture(
            pid: app.processIdentifier,
            toggleBinding: InputSourceLease.loadInstalledToggleBindingForFixture(),
            app: app,
            fileURL: fileURL,
            driver: driver,
            accessibility: accessibility
        )
        try fixture.focus()
        return fixture
    }

    func focus() throws {
        app.activate()
        try Poll.wait(timeout: 5, description: "TextEdit focused editor") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid
                && self.accessibility.focusedValue(pid: self.pid) != nil
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        // `activate()` is asynchronous. Sending Cmd+W before TextEdit is actually
        // frontmost can close the Chrome fixture that was launched next, turning an
        // IME assertion into an unrelated AX/window failure.
        if (try? focus()) != nil {
            driver.clearFocusedText()
            driver.keyPair(.a, flags: .maskCommand)
            driver.keyPair(1, flags: .maskCommand)
            driver.keyPair(13, flags: .maskCommand)
        }
        app.terminate()
        _ = try? Poll.wait(timeout: 5, description: "TextEdit fixture shutdown") {
            self.app.isTerminated
        }
        if !app.isTerminated {
            app.forceTerminate()
            _ = try? Poll.wait(timeout: 5, description: "TextEdit fixture forced shutdown") {
                self.app.isTerminated
            }
        }
        if !app.isTerminated {
            print("경고: 격리 TextEdit fixture를 종료하지 못했습니다: pid=\(pid)")
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    deinit { close() }
}

private final class ClipboardLease {
    private struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]
    private var restored = false

    init() {
        let pasteboard = NSPasteboard.general
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func replace(with string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func restore() {
        guard !restored else { return }
        restored = true
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restoredItems = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }

    deinit { restore() }
}

private enum Poll {
    static func wait(
        timeout: TimeInterval,
        interval: TimeInterval = 0.025,
        description: String,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(interval)))
        } while Date() < deadline
        if condition() { return }
        throw HangyeolE2EError.conditionTimedOut(description)
    }
}

private extension InputSourceLease {
    static func loadInstalledToggleBindingForFixture() -> KeyBinding {
        loadInstalledToggleBinding()
    }
}
