import Testing
import Cocoa
import Carbon.HIToolbox
@testable import HangyeolCore

// MARK: - ClientContext Tests

@Suite("ClientContext Struct")
struct ClientContextTests {
    
    @Test("Finder detection by bundle ID")
    func finderDetection() {
        let finderCtx = ClientContext(
            bundleId: "com.apple.finder",
            hasTextInputCapability: true,
            isLikelyDesktopArea: false
        )
        
        #expect(finderCtx.isFinder)
        #expect(!finderCtx.shouldUseImmediateMode, "Finder with text capability and non-desktop should use normal mode")
    }
    
    @Test("Finder desktop uses immediate mode")
    func finderDesktopShouldUseImmediateMode() {
        let desktopCtx = ClientContext(
            bundleId: "com.apple.finder",
            hasTextInputCapability: true,
            isLikelyDesktopArea: true
        )
        
        #expect(desktopCtx.isFinder)
        #expect(desktopCtx.shouldUseImmediateMode)
    }
    
    @Test("Finder rename fields stay in marked-text mode even without advertised attributes")
    func finderRenameWithoutAdvertisedAttributesUsesMarkedText() {
        let noTextCtx = ClientContext(
            bundleId: "com.apple.finder",
            hasTextInputCapability: false,
            isLikelyDesktopArea: false
        )
        
        #expect(!noTextCtx.shouldUseImmediateMode)
    }

    @Test("Finder rename client is analyzed from its field coordinates")
    func finderRenameClientUsesFieldCoordinates() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.finder"
        client.validAttributesValue = []
        client.firstRectValue = NSRect(x: 420, y: 260, width: 120, height: 22)
        client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)

        let context = ClientContextDetector.analyze(
            client: client,
            experimentalDirectInsertion: false
        )

        #expect(!context.hasTextInputCapability)
        #expect(!context.isLikelyDesktopArea)
        #expect(!context.shouldUseImmediateMode)
        #expect(HostAdapterResolver.mode(
            for: context,
            experimentalDirectInsertion: false
        ) == .markedText)
    }

    @Test("Finder rename evidence survives the Secure Input gate without weakening fallback")
    func finderRenameSecureInputTrustIsNarrow() {
        let renameClient = FakeIMKTextInput()
        renameClient.bundleID = "com.apple.finder"
        renameClient.validAttributesValue = []
        renameClient.firstRectValue = NSRect(x: 420, y: 260, width: 120, height: 22)
        renameClient.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
        let renameContext = ClientContextDetector.analyze(
            client: renameClient,
            experimentalDirectInsertion: false
        )
        var renameSelectionReads = 0
        let renameSignals = HangyeolInputController.secureInputSignals(
            context: renameContext,
            hasGlobalSecureInput: false,
            selectedRange: {
                renameSelectionReads += 1
                return renameClient.selectedRange()
            }
        )

        #expect(renameContext.isConfirmedFinderTextTarget)
        #expect(!SecureInputPolicy.shouldPassThrough(renameSignals))
        #expect(renameSelectionReads == 0)

        let desktopClient = FakeIMKTextInput()
        desktopClient.bundleID = "com.apple.finder"
        desktopClient.validAttributesValue = []
        desktopClient.firstRectValue = NSRect(x: 5, y: 20, width: 0, height: 0)
        desktopClient.selectedRangeValue = NSRange(location: NSNotFound, length: 0)
        let desktopContext = ClientContextDetector.analyze(
            client: desktopClient,
            experimentalDirectInsertion: false
        )
        let desktopSignals = HangyeolInputController.secureInputSignals(
            context: desktopContext,
            hasGlobalSecureInput: false,
            selectedRange: desktopClient.selectedRange
        )

        #expect(!desktopContext.isConfirmedFinderTextTarget)
        #expect(SecureInputPolicy.shouldPassThrough(desktopSignals))

        let globallySecureSignals = HangyeolInputController.secureInputSignals(
            context: renameContext,
            hasGlobalSecureInput: true,
            selectedRange: {
                Issue.record("Global Secure Input must not probe the client selection")
                return NSRange(location: 0, length: 0)
            }
        )
        #expect(SecureInputPolicy.shouldPassThrough(globallySecureSignals))

        let unknownAppKit = ClientContext(
            bundleId: "com.example.passwordlike",
            hasTextInputCapability: false,
            isLikelyDesktopArea: false
        )
        let unknownSignals = HangyeolInputController.secureInputSignals(
            context: unknownAppKit,
            hasGlobalSecureInput: false,
            selectedRange: { NSRange(location: NSNotFound, length: 0) }
        )
        #expect(!unknownAppKit.isConfirmedFinderTextTarget)
        #expect(SecureInputPolicy.shouldPassThrough(unknownSignals))

        for invalidRect in [
            NSRect.null,
            NSRect(x: 420, y: 260, width: 120, height: 0),
            NSRect(x: 20_000_000, y: 20_000_000, width: 120, height: 22)
        ] {
            let invalidGeometryClient = FakeIMKTextInput()
            invalidGeometryClient.bundleID = "com.apple.finder"
            invalidGeometryClient.validAttributesValue = []
            invalidGeometryClient.firstRectValue = invalidRect
            invalidGeometryClient.selectedRangeValue = NSRange(
                location: NSNotFound,
                length: 0
            )
            let invalidGeometryContext = ClientContextDetector.analyze(
                client: invalidGeometryClient,
                experimentalDirectInsertion: false
            )
            var selectionReads = 0
            let invalidGeometrySignals = HangyeolInputController.secureInputSignals(
                context: invalidGeometryContext,
                hasGlobalSecureInput: false,
                selectedRange: {
                    selectionReads += 1
                    return invalidGeometryClient.selectedRange()
                }
            )

            #expect(invalidGeometryContext.capabilities.caretGeometry == .unavailable)
            #expect(!invalidGeometryContext.isConfirmedFinderTextTarget)
            #expect(SecureInputPolicy.shouldPassThrough(invalidGeometrySignals))
            #expect(selectionReads == 1)
        }
    }

    @Test("Finder rename selection overrides the dummy-window coordinate")
    func finderRenameSelectionOverridesDummyCoordinate() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.finder"
        client.validAttributesValue = []
        client.firstRectValue = NSRect(x: 5, y: 20, width: 0, height: 0)
        client.selectedRangeValue = NSRange(location: 4, length: 0)

        let context = ClientContextDetector.analyze(
            client: client,
            experimentalDirectInsertion: false
        )

        // Secure classification keeps using advertised marked-text capability,
        // while adapter routing preserves the raw dummy-coordinate observation.
        #expect(!context.hasTextInputCapability)
        #expect(context.isLikelyDesktopArea)
        #expect(context.capabilities.hasUsableSelection)
        #expect(context.hostSurface == .appKit)
        #expect(!context.shouldUseImmediateMode)
        #expect(HostAdapterResolver.mode(
            for: context,
            experimentalDirectInsertion: false
        ) == .markedText)
    }

    @Test("Finder document-access capability overrides the desktop sentinel")
    func finderDocumentAccessOverridesDesktopSentinel() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.finder"
        client.validAttributesValue = []
        client.firstRectValue = NSRect(x: 5, y: 20, width: 0, height: 0)
        client.selectedRangeValue = NSRange(location: NSNotFound, length: NSNotFound)
        client.supportedPropertyValues = [
            TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag)
        ]

        let context = ClientContextDetector.analyze(
            client: client,
            experimentalDirectInsertion: false
        )

        #expect(context.capabilities.advertisesDocumentAccess)
        #expect(!context.hasTextInputCapability)
        #expect(context.hostSurface == .appKit)
        #expect(context.documentAccessSafe)
        #expect(!context.shouldUseImmediateMode)
        #expect(HostAdapterResolver.mode(
            for: context,
            experimentalDirectInsertion: false
        ) == .markedText)
    }

    @Test("Finder desktop keeps immediate mode without an editable selection")
    func finderDesktopWithoutSelectionStaysImmediate() {
        let client = FakeIMKTextInput()
        client.bundleID = "com.apple.finder"
        client.validAttributesValue = []
        client.firstRectValue = NSRect(x: 5, y: 20, width: 0, height: 0)
        client.selectedRangeValue = NSRange(location: NSNotFound, length: 0)

        let context = ClientContextDetector.analyze(
            client: client,
            experimentalDirectInsertion: false
        )

        #expect(!context.hasTextInputCapability)
        #expect(!context.capabilities.hasEditableTextEvidence)
        #expect(context.hostSurface == .finderNonText)
        #expect(context.isLikelyDesktopArea)
        #expect(context.shouldUseImmediateMode)
        #expect(HostAdapterResolver.mode(
            for: context,
            experimentalDirectInsertion: false
        ) == .immediate)
    }
    
    @Test("Non-Finder apps never use immediate mode")
    func nonFinderAppNeverUsesImmediateMode() {
        let safariCtx = ClientContext(
            bundleId: "com.apple.Safari",
            hasTextInputCapability: true,
            isLikelyDesktopArea: true
        )
        
        #expect(!safariCtx.isFinder)
        #expect(!safariCtx.shouldUseImmediateMode)
    }
    
    @Test("Empty bundle ID is not Finder")
    func unknownBundleId() {
        let unknownCtx = ClientContext(
            bundleId: "",
            hasTextInputCapability: false,
            isLikelyDesktopArea: false
        )
        
        #expect(!unknownCtx.isFinder)
        #expect(!unknownCtx.shouldUseImmediateMode)
    }

    @Test("Secure input policy passes through global secure input")
    func secureInputPolicyPassesThroughGlobalSecureInput() {
        #expect(SecureInputPolicy.shouldPassThrough(SecureInputSignals(
            bundleId: "com.example.messenger",
            hasTextInputCapability: true,
            hasInvalidSelection: false,
            hasGlobalSecureInput: true
        )))
    }

    @Test("Secure input policy handles invalid selection capability cases")
    func secureInputPolicyHandlesInvalidSelectionCapabilityCases() {
        #expect(SecureInputPolicy.shouldPassThrough(SecureInputSignals(
            bundleId: "com.example.PasswordPanel",
            hasTextInputCapability: false,
            hasInvalidSelection: true,
            hasGlobalSecureInput: false
        )))

        #expect(!SecureInputPolicy.shouldPassThrough(SecureInputSignals(
            bundleId: "com.example.messenger",
            hasTextInputCapability: true,
            hasInvalidSelection: true,
            hasGlobalSecureInput: false
        )))

        #expect(!SecureInputPolicy.shouldPassThrough(SecureInputSignals(
            bundleId: "com.google.Chrome",
            hasTextInputCapability: true,
            hasInvalidSelection: true,
            hasGlobalSecureInput: false
        )))
    }

    @Test("Selection is probed only for the unresolved no-capability case")
    func secureInputPolicySelectionProbeBoundary() {
        #expect(SecureInputPolicy.requiresSelectionProbe(
            bundleId: "com.example.PasswordPanel",
            hasTextInputCapability: false,
            hasGlobalSecureInput: false
        ))
        #expect(!SecureInputPolicy.requiresSelectionProbe(
            bundleId: "com.example.messenger",
            hasTextInputCapability: true,
            hasGlobalSecureInput: false
        ))
        #expect(!SecureInputPolicy.requiresSelectionProbe(
            bundleId: "com.example.PasswordPanel",
            hasTextInputCapability: false,
            hasGlobalSecureInput: true
        ))
        #expect(!SecureInputPolicy.requiresSelectionProbe(
            bundleId: "com.apple.SecurityAgent",
            hasTextInputCapability: false,
            hasGlobalSecureInput: false
        ))
    }

    @Test("Secure input policy always passes through system secure clients")
    func secureInputPolicyPassesThroughSystemSecureClients() {
        #expect(SecureInputPolicy.shouldPassThrough(SecureInputSignals(
            bundleId: "com.apple.SecurityAgent",
            hasTextInputCapability: true,
            hasInvalidSelection: false,
            hasGlobalSecureInput: false
        )))
    }

    // Commit-on-app-deactivate is now a host-agnostic behaviour in
    // HangyeolInputController (no per-app policy), so there is no longer a
    // bundle-ID predicate to unit-test here.

    @Test("Client compatibility policy flags GoodNotes for direct-newline Return")
    func goodNotesNeedsDirectNewlineAfterReturnCommit() {
        #expect(ClientCompatibilityPolicy.needsDirectNewlineAfterReturnCommit(bundleId: "com.goodnotesapp.x"))
        #expect(!ClientCompatibilityPolicy.needsDirectNewlineAfterReturnCommit(bundleId: "com.openai.codex"))
    }

    @Test("Client compatibility policy consumes Return after Hangul commit for Hermes")
    func hermesConsumesReturnAfterCompositionCommit() {
        #expect(ClientCompatibilityPolicy.needsReturnConsumedAfterCompositionCommit(bundleId: "com.nousresearch.hermes"))
        #expect(ClientCompatibilityPolicy.needsReturnConsumedAfterCompositionCommit(bundleId: "com.nousresearch.hermes.setup"))
        #expect(!ClientCompatibilityPolicy.needsReturnConsumedAfterCompositionCommit(bundleId: "com.openai.codex"))
    }

    @Test("Client compatibility policy prefers direct insertion for Hermes")
    func hermesPrefersDirectInsertionForComposition() {
        #expect(ClientCompatibilityPolicy.prefersDirectInsertionForComposition(bundleId: "com.nousresearch.hermes"))
        #expect(ClientCompatibilityPolicy.prefersDirectInsertionForComposition(bundleId: "com.nousresearch.hermes.setup"))
        #expect(!ClientCompatibilityPolicy.prefersDirectInsertionForComposition(bundleId: "com.openai.codex"))
    }

    // MARK: - Resolution / Desktop Detection (migrated from ResolutionTests.swift)
    
    @Test("Desktop detection — standard resolution")
    func desktopDetectionStandard() {
        #expect(isDesktopArea(x: 5.0, y: 20.0), "Should detect Desktop at (5, 20)")
        #expect(!isDesktopArea(x: 800.0, y: 600.0), "Should NOT detect Search Bar at (800, 600)")
    }
    
    @Test("Desktop detection — 5K Retina")
    func desktopDetection5K() {
        #expect(isDesktopArea(x: 5.0, y: 20.0), "5K: Desktop coords remain small in Points")
        #expect(!isDesktopArea(x: 2400.0, y: 1350.0), "5K: Search Bar at (2400, 1350)")
    }
    
    @Test("Desktop detection — multi-monitor with negative coords")
    func desktopDetectionMultiMonitor() {
        #expect(!isDesktopArea(x: -1000.0, y: 500.0), "Multi-mon: Left monitor")
        #expect(!isDesktopArea(x: 500.0, y: -1000.0), "Multi-mon: Bottom monitor")
    }
    
    private func isDesktopArea(x: Double, y: Double) -> Bool {
        return x < Double(HangyeolConfig.finderDesktopThreshold) && y < Double(HangyeolConfig.finderDesktopThreshold)
    }
}
