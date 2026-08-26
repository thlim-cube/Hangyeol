import Testing
import Cocoa
@testable import PriTypeCore

private final class DelayedMarkedRangeClient: FakeIMKTextInput {
    private let markLocation = 2
    private var nonemptyUpdateCount = 0
    private var liveMarkedLength = 0
    private(set) var orderedHostCalls: [String] = []

    init(initialSelectionLocation: Int = NSNotFound) {
        super.init()
        document = "가나다라"
        selectedRangeValue = NSRange(location: initialSelectionLocation, length: 0)
    }

    override func setMarkedText(
        _ string: Any!,
        selectionRange: NSRange,
        replacementRange: NSRange
    ) {
        let text = (string as? NSAttributedString)?.string
            ?? (string as? String)
            ?? ""
        markCalls.append(text)
        markedText = text
        guard !text.isEmpty else {
            markedRangeValue = NSRange(location: NSNotFound, length: 0)
            return
        }

        var units = Array(document.utf16)
        units.replaceSubrange(
            markLocation..<(markLocation + liveMarkedLength),
            with: text.utf16
        )
        document = String(decoding: units, as: UTF16.self)
        liveMarkedLength = text.utf16.count

        nonemptyUpdateCount += 1
        guard nonemptyUpdateCount > 1 else {
            markedRangeValue = NSRange(location: NSNotFound, length: 0)
            selectedRangeValue = NSRange(location: NSNotFound, length: 0)
            return
        }
        markedRangeValue = NSRange(
            location: markLocation,
            length: text.utf16.count
        )
        selectedRangeValue = NSRange(
            location: markLocation + text.utf16.count,
            length: 0
        )
    }

    override func insertText(_ string: Any!, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string
            ?? (string as? String)
            ?? ""
        var units = Array(document.utf16)
        if replacementRange.location == NSNotFound {
            orderedHostCalls.append("insert:\(text)")
            units.replaceSubrange(
                markLocation..<(markLocation + liveMarkedLength),
                with: text.utf16
            )
            liveMarkedLength = 0
            selectedRangeValue = NSRange(
                location: markLocation + text.utf16.count,
                length: 0
            )
        } else {
            orderedHostCalls.append(
                "delete:\(replacementRange.location):\(replacementRange.length)"
            )
            let end = min(
                units.count,
                replacementRange.location + replacementRange.length
            )
            units.replaceSubrange(replacementRange.location..<end, with: [])
        }
        document = String(decoding: units, as: UTF16.self)
        markedText = ""
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
    }
}

// MARK: - HostAdapterResolver

/// The delivery-mode decision is the single point where a session picks how
/// composition output reaches the host (marked text / direct insertion / immediate).
@Suite("HostAdapterResolver")
struct HostAdapterResolverTests {
    private func context(
        bundleId: String,
        hasTextInputCapability: Bool = true,
        isLikelyDesktopArea: Bool = false,
        documentAccessSafe: Bool = false,
        usesBlinkNativeTextClient: Bool = false
    ) -> ClientContext {
        ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: hasTextInputCapability,
            isLikelyDesktopArea: isLikelyDesktopArea,
            documentAccessSafe: documentAccessSafe,
            usesBlinkNativeTextClient: usesBlinkNativeTextClient
        )
    }

    private func mode(
        for context: ClientContext,
        experimentalDirectInsertion: Bool = false
    ) -> InputDeliveryMode {
        HostAdapterResolver.mode(
            for: context,
            experimentalDirectInsertion: experimentalDirectInsertion
        )
    }

    private func analyzedContext(
        bundleId: String,
        expectedHostSurface: HostSurface,
        documentAccessSafe: Bool
    ) -> ClientContext {
        let capabilities = IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: true,
            advertisesDocumentAccess: documentAccessSafe,
            hasUsableSelection: documentAccessSafe,
            advertisesBlinkReplacementRange: expectedHostSurface == .blinkWeb,
            caretGeometry: .usable
        )
        let hostSurface = HostSurfaceResolver.resolve(
            bundleId: bundleId,
            capabilities: capabilities
        )
        #expect(hostSurface == expectedHostSurface)
        return ClientContext(
            bundleId: bundleId,
            hasTextInputCapability: true,
            isLikelyDesktopArea: false,
            documentAccessSafe: documentAccessSafe,
            capabilities: capabilities,
            hostSurface: hostSurface
        )
    }

    @Test("Finder desktop context resolves to immediate mode")
    func finderDesktopIsImmediate() {
        let ctx = context(bundleId: "com.apple.finder", hasTextInputCapability: false, isLikelyDesktopArea: true)
        #expect(mode(for: ctx) == .immediate)
    }

    @Test("Finder rename field uses marked text even when attributes are empty")
    func finderRenameWithoutAttributesIsMarked() {
        let ctx = context(
            bundleId: "com.apple.finder",
            hasTextInputCapability: false,
            isLikelyDesktopArea: false
        )
        #expect(mode(for: ctx) == .markedText)
    }

    @Test("Default context resolves to canonical marked text")
    func defaultIsMarkedText() {
        let ctx = context(bundleId: "com.apple.TextEdit", documentAccessSafe: true)
        #expect(mode(for: ctx) == .markedText)
    }

    @Test("Direct-insertion-preferring host without document access stays on marked text")
    func directPreferenceRequiresDocumentAccess() {
        let ctx = context(bundleId: "com.nousresearch.hermes", documentAccessSafe: false)
        #expect(mode(for: ctx) == .markedText)
    }

    @Test("Direct-insertion-preferring host with document access gets direct insertion")
    func directPreferenceWithDocumentAccess() {
        let ctx = context(bundleId: "com.nousresearch.hermes", documentAccessSafe: true)
        #expect(mode(for: ctx) == .directInsertion)
    }

    @Test("Denylisted Electron/Chromium hosts never get direct insertion")
    func denylistedHostStaysMarked() {
        let ctx = context(bundleId: "com.google.Chrome", documentAccessSafe: true)
        #expect(mode(for: ctx) == .markedText)
    }

    @Test("Chrome native fields use direct insertion without entering marked text")
    func blinkNativeFieldUsesDirectInsertion() {
        let ctx = context(
            bundleId: "com.google.Chrome",
            documentAccessSafe: true,
            usesBlinkNativeTextClient: true
        )
        #expect(mode(for: ctx) == .directInsertion)
    }

    @Test("Electron fields that look native stay on marked text")
    func electronNativeLookingFieldStaysMarked() {
        for bundleId in [
            "com.tinyspeck.slackmacgap",
            "com.openai.codex",
            "com.microsoft.VSCode"
        ] {
            let ctx = context(
                bundleId: bundleId,
                documentAccessSafe: true,
                usesBlinkNativeTextClient: true
            )
            #expect(mode(for: ctx) == .markedText)
        }
    }

    @Test("Experimental direct insertion still requires document access and a safe host")
    func experimentalDirectInsertionKeepsSafetyGates() {
        let native = context(bundleId: "com.apple.TextEdit", documentAccessSafe: true)
        let unreadable = context(bundleId: "com.apple.TextEdit", documentAccessSafe: false)
        let denylisted = context(bundleId: "com.google.Chrome", documentAccessSafe: true)

        #expect(mode(for: native, experimentalDirectInsertion: true) == .directInsertion)
        #expect(mode(for: unreadable, experimentalDirectInsertion: true) == .markedText)
        #expect(mode(for: denylisted, experimentalDirectInsertion: true) == .markedText)
    }

    @Test("Blink web capability owns adapter mode and marked payload")
    func blinkWebCapabilityStaysCanonicalEndToEnd() {
        for bundleId in [
            "com.example.opaque",
            "com.naver.whale",
            "com.spotify.client"
        ] {
            let context = analyzedContext(
                bundleId: bundleId,
                expectedHostSurface: .blinkWeb,
                documentAccessSafe: true
            )
            #expect(mode(for: context, experimentalDirectInsertion: true) == .markedText)

            let client = FakeIMKTextInput()
            let adapter = HostAdapterResolver.makeAdapter(
                for: client,
                context: context,
                experimentalDirectInsertion: true
            )
            adapter.setMarkedText("가")

            #expect(adapter.deliveryMode == .markedText)
            #expect(client.markedPayloadWasAttributed == [false])
        }
    }

    @Test("Hermes keeps its explicit direct-insertion contract on Blink web")
    func hermesBlinkWebCompatibilityStaysDirect() {
        for bundleId in [
            "com.nousresearch.hermes",
            "com.nousresearch.hermes.setup"
        ] {
            let context = analyzedContext(
                bundleId: bundleId,
                expectedHostSurface: .blinkWeb,
                documentAccessSafe: true
            )
            #expect(mode(for: context, experimentalDirectInsertion: false) == .directInsertion)

            let adapter = HostAdapterResolver.makeAdapter(
                for: FakeIMKTextInput(),
                context: context,
                experimentalDirectInsertion: false
            )
            #expect(adapter.deliveryMode == .directInsertion)
            #expect(adapter.hostSurface == .blinkWeb)
        }
    }

    @Test("Native Blink and AppKit surfaces remain non-web delivery targets")
    func nonWebSurfacesKeepTheirOwnDelivery() {
        let blinkNative = analyzedContext(
            bundleId: "com.google.Chrome",
            expectedHostSurface: .blinkNative,
            documentAccessSafe: true
        )
        let appKit = analyzedContext(
            bundleId: "com.apple.TextEdit",
            expectedHostSurface: .appKit,
            documentAccessSafe: true
        )

        #expect(mode(for: blinkNative, experimentalDirectInsertion: false) == .directInsertion)
        #expect(mode(for: appKit, experimentalDirectInsertion: true) == .directInsertion)
        #expect(MarkedTextPayload.value("가", for: .blinkNative) is NSAttributedString)
        #expect(MarkedTextPayload.value("가", for: .appKit) is NSAttributedString)
    }

    @Test("Adapter success APIs reject writes after ownership is revoked")
    func adapterReportsRejectedClientWrites() {
        let client = FakeIMKTextInput()
        client.document = "a "
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        let adapter = MarkedTextAdapter(
            client: client,
            hostSurface: .appKit
        )
        adapter.setClientWriteValidator { false }

        #expect(!adapter.tryInsertText("A"))
        #expect(!adapter.tryReplaceTextBeforeCursor(length: 1, with: ". "))
        #expect(client.insertCalls.isEmpty)
        #expect(client.document == "a ")

        var directWriteAllowed = true
        let direct = DirectInsertionAdapter(
            client: client,
            hostSurface: .appKit
        )
        direct.setClientWriteValidator { directWriteAllowed }
        client.onSelectedRange = {
            client.onSelectedRange = nil
            directWriteAllowed = false
        }
        #expect(!direct.tryInsertText("A"))
        #expect(client.insertCalls.isEmpty)
    }

    @Test("Blink web content receives plain marked text while native hosts keep attributes")
    func markedTextPayloadMatchesHostCompatibility() {
        let blinkClient = FakeIMKTextInput()
        MarkedTextAdapter(
            client: blinkClient,
            hostSurface: .blinkWeb
        )
            .setMarkedText("가")
        #expect(blinkClient.markedPayloadWasAttributed == [false])

        let nativeClient = FakeIMKTextInput()
        MarkedTextAdapter(
            client: nativeClient,
            hostSurface: .appKit
        )
            .setMarkedText("가")
        #expect(nativeClient.markedPayloadWasAttributed == [true])
    }

    @Test("Marked adapter exposes only its live preedit to host-key transactions")
    func markedAdapterTracksHostTransactionText() {
        let client = FakeIMKTextInput()
        let adapter = MarkedTextAdapter(
            client: client,
            hostSurface: .blinkWeb
        )

        client.selectedRangeValue = NSRange(location: 2, length: 0)
        adapter.setMarkedText("마")
        #expect(adapter.hostTransactionMarkedText == "마")
        #expect(adapter.hostTransactionMarkedRange == NSRange(location: 2, length: 1))

        #expect(adapter.tryInsertText("마"))
        #expect(adapter.hostTransactionMarkedText == nil)
        #expect(adapter.hostTransactionMarkedRange == nil)
    }

    @Test("Marked adapter recovers a delayed range before Forward Delete after Backspace")
    func markedAdapterRecoversDelayedRangeAcrossBackspace() {
        let cases: [([String], String)] = [
            (["ㄱ", "가"], "가"),
            (["ㅁ", "마", "말"], "말"),
            (["ㅁ", "마", "말", "맑", "말"], "말")
        ]

        for initialSelection in [NSNotFound, 0] {
            for (preedits, finalPreedit) in cases {
                let client = DelayedMarkedRangeClient(
                    initialSelectionLocation: initialSelection
                )
                let adapter = MarkedTextAdapter(
                    client: client,
                    hostSurface: .blinkWeb
                )

                for preedit in preedits {
                    adapter.setMarkedText(preedit)
                }

                #expect(adapter.hostTransactionMarkedText == finalPreedit)
                #expect(adapter.hostTransactionMarkedRange == NSRange(location: 2, length: 1))
                #expect(adapter.tryPerformHostKeyTransaction(
                    keyCode: KeyCode.forwardDelete,
                    modifierFlags: NSEvent.ModifierFlags.function.rawValue,
                    commit: { adapter.insertText(finalPreedit) }
                ))
                #expect(client.orderedHostCalls == [
                    "insert:\(finalPreedit)",
                    "delete:3:1"
                ])
                #expect(client.document == "가나\(finalPreedit)라")
            }
        }
    }

    @Test("Forward Delete never trusts an unconfirmed stale preedit caret")
    func markedAdapterRejectsUnconfirmedStaleCaret() {
        let client = DelayedMarkedRangeClient(initialSelectionLocation: 1)
        let adapter = MarkedTextAdapter(
            client: client,
            hostSurface: .blinkWeb
        )

        adapter.setMarkedText("ㅁ")
        #expect(adapter.hostTransactionMarkedRange == nil)

        adapter.setMarkedText("마")
        #expect(adapter.hostTransactionMarkedRange == NSRange(location: 2, length: 1))
        #expect(adapter.tryPerformHostKeyTransaction(
            keyCode: KeyCode.forwardDelete,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            commit: { adapter.insertText("마") }
        ))
        #expect(client.orderedHostCalls == ["insert:마", "delete:3:1"])
        #expect(client.document == "가나마라")
    }
}

// MARK: - Composition renderer classification

@Suite("CompositionRenderer")
struct CompositionRendererTests {
    @Test("Known Blink/Electron hosts classify as blink")
    func knownBlinkHosts() {
        for id in [
            "com.google.Chrome",
            "com.anthropic.claudefordesktop",
            "com.microsoft.VSCode",
            "com.tinyspeck.slackmacgap",
            "com.naver.whale"
        ] {
            #expect(ClientCompatibilityPolicy.compositionRenderer(bundleId: id) == .blink, "\(id) should be blink")
        }
    }

    @Test("Keyword heuristic catches unlisted Chromium/Electron wrappers")
    func keywordHeuristic() {
        #expect(ClientCompatibilityPolicy.compositionRenderer(bundleId: "com.example.MyElectronApp") == .blink)
        #expect(ClientCompatibilityPolicy.compositionRenderer(bundleId: "org.chromium.Chromium") == .blink)
    }

    @Test("WebKit and native hosts classify as system — Safari must NOT be blink")
    func systemHosts() {
        for id in [
            "com.apple.Safari",                 // WebKit: needs exactly NSColor.clear
            "com.apple.SafariTechnologyPreview",
            "org.mozilla.firefox",              // Gecko
            "com.apple.TextEdit",
            "com.kakao.KakaoTalkMac",
            "com.apple.dt.Xcode"
        ] {
            #expect(ClientCompatibilityPolicy.compositionRenderer(bundleId: id) == .system, "\(id) should be system")
        }
    }
}

// MARK: - Marked-text payload compatibility

@Suite("MarkedTextPayload")
struct MarkedTextPayloadTests {
    @Test("Blink hosts receive a plain NSString marked payload")
    func blinkUsesPlainString() {
        let payload = MarkedTextPayload.value("가", for: .blinkWeb)
        #expect(payload is NSString)
        #expect(!(payload is NSAttributedString))
    }

    @Test("System hosts retain attributed marked text with a clear underline")
    func systemAttributes() throws {
        for hostSurface in [HostSurface.appKit, .blinkNative] {
            let payload = try #require(
                MarkedTextPayload.value("가", for: hostSurface) as? NSAttributedString
            )
            let attrs = payload.attributes(at: 0, effectiveRange: nil)
            #expect(attrs[.underlineStyle] as? Int == 0)
            let color = try #require(attrs[.underlineColor] as? NSColor)
            // WebKit's extraction fast path compares isEqual:NSColor.clearColor —
            // it must be the literal clear color, not a hand-built alpha-0 color.
            #expect(color == NSColor.clear)
        }
    }
}

@Suite("Blink text-client classification")
struct BlinkTextClientClassificationTests {
    @Test("Actual replacement-range capability selects Blink web before bundle fallback")
    func replacementRangeCapabilitySelectsBlinkWeb() {
        let capabilities = IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: true,
            advertisesDocumentAccess: true,
            hasUsableSelection: true,
            advertisesBlinkReplacementRange: true,
            caretGeometry: .unavailable
        )

        #expect(HostSurfaceResolver.resolve(
            bundleId: "com.google.Chrome",
            capabilities: capabilities
        ) == .blinkWeb)
    }

    @Test("Browser native field requires editable capability evidence")
    func browserNativeFieldRequiresCapabilityEvidence() {
        let editable = IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: true,
            advertisesDocumentAccess: true,
            hasUsableSelection: true,
            advertisesBlinkReplacementRange: false,
            caretGeometry: .unavailable
        )
        let unavailable = IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: false,
            advertisesDocumentAccess: false,
            hasUsableSelection: false,
            advertisesBlinkReplacementRange: false,
            caretGeometry: .unavailable
        )

        #expect(HostSurfaceResolver.resolve(
            bundleId: "com.google.Chrome",
            capabilities: editable
        ) == .blinkNative)
        #expect(HostSurfaceResolver.resolve(
            bundleId: "com.google.Chrome",
            capabilities: unavailable
        ) == .blinkWeb)
    }

    @Test("Electron bundle remains a secondary web fallback")
    func electronBundleIsSecondaryFallback() {
        let capabilities = IMKClientCapabilitySnapshot(
            advertisesMarkedTextAttributes: true,
            advertisesDocumentAccess: true,
            hasUsableSelection: true,
            advertisesBlinkReplacementRange: false,
            caretGeometry: .unavailable
        )

        #expect(HostSurfaceResolver.resolve(
            bundleId: "com.openai.codex",
            capabilities: capabilities
        ) == .blinkWeb)
    }

    @Test("Only browser bundles may use Blink native direct insertion")
    func nativeDirectInsertionIsBrowserOnly() {
        for bundleId in [
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac"
        ] {
            #expect(ClientCompatibilityPolicy.supportsBlinkNativeDirectInsertion(
                bundleId: bundleId
            ))
        }

        for bundleId in [
            "com.tinyspeck.slackmacgap",
            "com.openai.codex",
            "com.microsoft.VSCode",
            "com.example.UnknownElectronApp"
        ] {
            #expect(!ClientCompatibilityPolicy.supportsBlinkNativeDirectInsertion(
                bundleId: bundleId
            ))
        }
    }

    @Test("Context analysis normalizes both native attribute keys and NSString names")
    func contextAnalysisNormalizesAttributeNames() {
        for replacementAttribute in [
            NSAttributedString.Key("NSTextInputReplacementRangeAttributeName") as Any,
            "NSTextInputReplacementRangeAttributeName" as NSString
        ] {
            let webClient = FakeIMKTextInput()
            webClient.bundleID = "com.google.Chrome"
            webClient.validAttributesValue = [replacementAttribute]

            let webContext = ClientContextDetector.analyze(
                client: webClient,
                experimentalDirectInsertion: false
            )
            #expect(!webContext.usesBlinkNativeTextClient)
        }

        let nativeClient = FakeIMKTextInput()
        nativeClient.bundleID = "com.google.Chrome"
        nativeClient.validAttributesValue = [NSAttributedString.Key.underlineStyle]

        let nativeContext = ClientContextDetector.analyze(
            client: nativeClient,
            experimentalDirectInsertion: false
        )
        #expect(nativeContext.usesBlinkNativeTextClient)
        #expect(nativeContext.documentAccessSafe)
    }
}
