import Testing
import Cocoa
@testable import PriTypeCore

// MARK: - TextDeliveryPolicy

/// The delivery-mode decision is the single point where a session picks how
/// composition output reaches the host (marked text / direct insertion / immediate).
@Suite("TextDeliveryPolicy")
struct TextDeliveryPolicyTests {
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

    @Test("Finder desktop context resolves to immediate mode")
    func finderDesktopIsImmediate() {
        let ctx = context(bundleId: "com.apple.finder", hasTextInputCapability: false, isLikelyDesktopArea: true)
        #expect(TextDeliveryPolicy.mode(for: ctx) == .immediate)
    }

    @Test("Default context resolves to canonical marked text")
    func defaultIsMarkedText() {
        let ctx = context(bundleId: "com.apple.TextEdit", documentAccessSafe: true)
        #expect(TextDeliveryPolicy.mode(for: ctx) == .markedText)
    }

    @Test("Direct-insertion-preferring host without document access stays on marked text")
    func directPreferenceRequiresDocumentAccess() {
        let ctx = context(bundleId: "com.nousresearch.hermes", documentAccessSafe: false)
        #expect(TextDeliveryPolicy.mode(for: ctx) == .markedText)
    }

    @Test("Direct-insertion-preferring host with document access gets direct insertion")
    func directPreferenceWithDocumentAccess() {
        let ctx = context(bundleId: "com.nousresearch.hermes", documentAccessSafe: true)
        #expect(TextDeliveryPolicy.mode(for: ctx) == .directInsertion)
    }

    @Test("Denylisted Electron/Chromium hosts never get direct insertion")
    func denylistedHostStaysMarked() {
        let ctx = context(bundleId: "com.google.Chrome", documentAccessSafe: true)
        #expect(TextDeliveryPolicy.mode(for: ctx) == .markedText)
    }

    @Test("Chrome native fields use direct insertion without entering marked text")
    func blinkNativeFieldUsesDirectInsertion() {
        let ctx = context(
            bundleId: "com.google.Chrome",
            documentAccessSafe: true,
            usesBlinkNativeTextClient: true
        )
        #expect(TextDeliveryPolicy.mode(for: ctx) == .directInsertion)
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
            #expect(TextDeliveryPolicy.mode(for: ctx) == .markedText)
        }
    }

    @Test("Adapter success APIs reject writes after ownership is revoked")
    func adapterReportsRejectedClientWrites() {
        let client = FakeIMKTextInput()
        client.document = "a "
        client.selectedRangeValue = NSRange(location: 2, length: 0)
        let adapter = MarkedTextAdapter(client: client, bundleId: client.bundleID)
        adapter.setClientWriteValidator { false }

        #expect(!adapter.tryInsertText("A"))
        #expect(!adapter.tryReplaceTextBeforeCursor(length: 1, with: ". "))
        #expect(client.insertCalls.isEmpty)
        #expect(client.document == "a ")

        var directWriteAllowed = true
        let direct = DirectInsertionAdapter(client: client, bundleId: client.bundleID)
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
        MarkedTextAdapter(client: blinkClient, bundleId: "com.google.Chrome")
            .setMarkedText("가")
        #expect(blinkClient.markedPayloadWasAttributed == [false])

        let nativeClient = FakeIMKTextInput()
        MarkedTextAdapter(client: nativeClient, bundleId: "com.apple.TextEdit")
            .setMarkedText("가")
        #expect(nativeClient.markedPayloadWasAttributed == [true])
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
        let payload = MarkedTextPayload.value("가", forBundleId: "com.google.Chrome")
        #expect(payload is NSString)
        #expect(!(payload is NSAttributedString))
    }

    @Test("System hosts retain attributed marked text with a clear underline")
    func systemAttributes() throws {
        for bundleId in ["com.apple.TextEdit", "com.apple.Safari", "com.kakao.KakaoTalkMac"] {
            let payload = try #require(
                MarkedTextPayload.value("가", forBundleId: bundleId) as? NSAttributedString
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

    @Test("Chromium web content is identified by its replacement-range attribute")
    func webContentSignature() {
        #expect(ClientCompatibilityPolicy.usesBlinkWebContentTextClient(
            bundleId: "com.google.Chrome",
            validAttributeNames: ["NSUnderlineStyle", "NSTextInputReplacementRangeAttributeName"]
        ))
        #expect(!ClientCompatibilityPolicy.usesBlinkWebContentTextClient(
            bundleId: "com.google.Chrome",
            validAttributeNames: ["NSFont", "NSForegroundColor"]
        ))
        #expect(!ClientCompatibilityPolicy.usesBlinkWebContentTextClient(
            bundleId: "com.apple.TextEdit",
            validAttributeNames: ["NSTextInputReplacementRangeAttributeName"]
        ))
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

            let webContext = ClientContextDetector.analyze(client: webClient)
            #expect(!webContext.usesBlinkNativeTextClient)
        }

        let nativeClient = FakeIMKTextInput()
        nativeClient.bundleID = "com.google.Chrome"
        nativeClient.validAttributesValue = [NSAttributedString.Key.underlineStyle]

        let nativeContext = ClientContextDetector.analyze(client: nativeClient)
        #expect(nativeContext.usesBlinkNativeTextClient)
        #expect(nativeContext.documentAccessSafe)
    }
}
